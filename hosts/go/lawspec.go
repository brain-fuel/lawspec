// Package lawspec runs LawSpec in Go. The LawSpec application is the Haskell
// core, a WebAssembly module this package downloads once per release from
// the npm package @goforgedev/core and checks against the SHA-256 it
// records (ref:DEC-go-core-download); this package runs it
// with wazero and performs the primitive effects (files, processes, the
// terminal, the network) the core asks for. It holds no LawSpec logic.
// docs/reference/host-effects.md specifies the boundary.
// ref:DEC-host-effect-abi
//
//	host, err := lawspec.New(ctx)
//	if err != nil { ... }
//	defer host.Close(ctx)
//	outcome, err := host.Main(ctx, []string{"fmt", "--check", "."}, dir)
package lawspec

import (
	"context"
	"crypto/rand"
	"crypto/sha256"
	"encoding/binary"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	goruntime "runtime"

	"github.com/tetratelabs/wazero"
	"github.com/tetratelabs/wazero/api"
	"github.com/tetratelabs/wazero/experimental"
	"github.com/tetratelabs/wazero/imports/wasi_snapshot_preview1"

	"goforge.dev/lawspec/internal/core"
	"goforge.dev/lawspec/internal/effects"
)

// Outcome is the core's answer to one invocation. Exactly one of Exit,
// NotPorted and Error is set.
type Outcome struct {
	// Exit is the command's exit code.
	Exit *int `json:"exit"`
	// NotPorted names a command the core does not run yet. The core decides
	// this before performing any effect.
	NotPorted *string `json:"notPorted"`
	// Error is a malformed invocation.
	Error *OutcomeError `json:"error"`
}

// OutcomeError is the core's refusal of an invocation.
type OutcomeError struct {
	Kind    string `json:"kind"`
	Message string `json:"message"`
}

// Option configures a Host.
type Option func(*config)

type config struct {
	wasm      []byte
	cacheDir  string
	noCache   bool
	workers   int
	resources string
	canon     string
	stdin     io.Reader
	stdout    io.Writer
	stderr    io.Writer
}

// WithCore runs the given core module instead of this release's, which
// New otherwise downloads (see New). The module is not checked against the
// recorded SHA-256: it is for development and parity runs of a core built
// from source.
func WithCore(wasm []byte) Option {
	return func(c *config) { c.wasm = wasm }
}

// WithCompilationCache keeps wazero's compiled code in dir. The default is
// lawspec/wazero in the user cache directory (os.UserCacheDir). An empty
// dir disables the cache.
func WithCompilationCache(dir string) Option {
	return func(c *config) {
		c.cacheDir = dir
		c.noCache = dir == ""
	}
}

// WithCompilationWorkers caps the goroutines wazero compiles the core on.
// The default, used when n <= 0, is runtime.GOMAXPROCS(0): the CPUs the
// process may use, which on Linux honours its CPU affinity and, for a main
// module declaring go 1.25 or later, its cgroup CPU limit. A cached
// compilation compiles nothing, so the cap matters only on a cache miss.
func WithCompilationWorkers(n int) Option {
	return func(c *config) { c.workers = n }
}

// WithResources names the directory of the package resources the core
// reads, such as the assets lawspec learn serves: an npm package's
// directory, with learn/, core.wasm, core.wasm.gz and core_jsffi.js. The Go
// host ships none of its own; without this option lawspec learn reports
// its assets missing. A relative dir is taken from the working directory.
func WithResources(dir string) Option {
	return func(c *config) { c.resources = dir }
}

// WithCanon names the Canon bundle the core runs for lawspec project: a
// directory holding the canon executable and the presets directory that
// project init and adopt copy into .ricestax/, as tools/build-canon.sh lays
// it out. The Go module embeds no Canon; without this option the core
// downloads this release's @goforgedev/canon-<platform> package from the npm
// registry (or LAWSPEC_CANON_REGISTRY) the first time a project command
// needs Canon, checks it against the SHA-256 the core records, and keeps it
// under lawspec/canon in the user cache directory (os.UserCacheDir). A
// relative dir is taken from the working directory.
func WithCanon(dir string) Option {
	return func(c *config) { c.canon = dir }
}

// WithStdio sets the streams the input and output effects use. A nil
// stream is the process's own.
func WithStdio(stdin io.Reader, stdout, stderr io.Writer) Option {
	return func(c *config) {
		c.stdin, c.stdout, c.stderr = stdin, stdout, stderr
	}
}

// DefaultCacheDir is where compiled code is kept by default.
func DefaultCacheDir() (string, error) {
	base, err := os.UserCacheDir()
	if err != nil {
		return "", err
	}
	return filepath.Join(base, "lawspec", "wazero"), nil
}

// Host is the compiled core, ready to run invocations. Each invocation runs
// in a fresh instance of the module. A Host is safe for concurrent use.
type Host struct {
	config   config
	runtime  wazero.Runtime
	compiled wazero.CompiledModule
	// build is the SHA-256 of the core module, in hexadecimal: the core
	// names its compiler cache folder by it and keys native test results by
	// it and the host.
	build string
}

type effectsKey struct{}

// New compiles the core. The first compilation of a core takes seconds; the
// compilation cache makes later ones much faster. A cache directory that
// cannot be created is skipped.
//
// Without WithCore, the core is this release's: kept under lawspec/core in
// the user cache directory (os.UserCacheDir) or, the first time, downloaded
// from the npm registry (or the HTTPS registry LAWSPEC_CORE_REGISTRY names)
// as the package @goforgedev/core, and used only if it matches the SHA-256
// this package records.
func New(ctx context.Context, options ...Option) (*Host, error) {
	var c config
	for _, option := range options {
		option(&c)
	}
	if c.wasm == nil {
		cache, _ := os.UserCacheDir()
		wasm, err := core.Load(ctx, core.Source{Cache: cache, Registry: os.Getenv(core.RegistryEnvironment)})
		if err != nil {
			return nil, err
		}
		c.wasm = wasm
	}
	// The core carries no DWARF, and the host reports no guest source
	// positions. With debug information on, wazero after v1.12.0 records a
	// source offset for every function even without DWARF, which also turns
	// off its shared trap exits: about 230 MB more cache and 400 MB more
	// resident memory at a cached start for this core.
	runtimeConfig := wazero.NewRuntimeConfigCompiler().WithDebugInfoEnabled(false)
	if !c.noCache {
		dir := c.cacheDir
		if dir == "" {
			dir, _ = DefaultCacheDir()
		}
		if dir != "" {
			if cache, err := wazero.NewCompilationCacheWithDir(dir); err == nil {
				runtimeConfig = runtimeConfig.WithCompilationCache(cache)
			}
		}
	}
	runtime := wazero.NewRuntimeWithConfig(ctx, runtimeConfig)
	if _, err := wasi_snapshot_preview1.Instantiate(ctx, runtime); err != nil {
		runtime.Close(ctx)
		return nil, err
	}
	_, err := runtime.NewHostModuleBuilder("lawspec_host").
		NewFunctionBuilder().
		WithFunc(perform).
		Export("perform").
		Instantiate(ctx)
	if err != nil {
		runtime.Close(ctx)
		return nil, err
	}
	// Compiling functions in parallel takes a cold start from about 9 s to
	// under 2 s; wazero compiles on one goroutine by default.
	workers := c.workers
	if workers <= 0 {
		workers = goruntime.GOMAXPROCS(0)
	}
	compiled, err := runtime.CompileModule(experimental.WithCompilationWorkers(ctx, workers), c.wasm)
	if err != nil {
		runtime.Close(ctx)
		return nil, fmt.Errorf("compile the LawSpec core: %w", err)
	}
	sum := sha256.Sum256(c.wasm)
	return &Host{config: c, runtime: runtime, compiled: compiled, build: hex.EncodeToString(sum[:])}, nil
}

// Close releases the compiled core.
func (h *Host) Close(ctx context.Context) error {
	return h.runtime.Close(ctx)
}

// Main runs one CLI invocation: argv without the program name, in the
// absolute working directory cwd.
func (h *Host) Main(ctx context.Context, argv []string, cwd string) (Outcome, error) {
	if argv == nil {
		argv = []string{}
	}
	invocation := map[string]any{
		"abi":   effects.ABI,
		"argv":  argv,
		"cwd":   cwd,
		"build": h.build,
		"host":  map[string]string{"kind": "go", "version": goruntime.Version()},
	}
	if h.config.resources != "" {
		resources, err := filepath.Abs(h.config.resources)
		if err != nil {
			return Outcome{}, err
		}
		invocation["resources"] = resources
	}
	canon, err := canonTool(h.config.canon, goruntime.GOOS, goruntime.GOARCH, os.UserCacheDir)
	if err != nil {
		return Outcome{}, err
	}
	if canon != nil {
		invocation["tools"] = map[string]any{"canon": canon}
	}
	return h.run(ctx, invocation)
}

// canonTool is the invocation's tools.canon: the bundle WithCanon names
// or, without one, the platform and cache directory the core downloads
// this release's Canon package into and verifies it in. The download, its
// digest check and the unpacking are the core's; a platform with no
// package, or no user cache directory, gets no Canon.
func canonTool(bundle, goos, goarch string, userCacheDir func() (string, error)) (map[string]any, error) {
	if bundle != "" {
		canon, err := filepath.Abs(bundle)
		if err != nil {
			return nil, err
		}
		return map[string]any{
			"command": []string{filepath.Join(canon, "canon")},
			"presets": filepath.Join(canon, "presets"),
		}, nil
	}
	platform, ok := canonPlatforms[goos+"/"+goarch]
	if !ok {
		return nil, nil
	}
	base, err := userCacheDir()
	if err != nil {
		return nil, nil
	}
	cache, err := filepath.Abs(filepath.Join(base, "lawspec"))
	if err != nil {
		return nil, nil
	}
	return map[string]any{
		"download": map[string]string{"platform": platform, "cache": cache},
	}, nil
}

// canonPlatforms are the platforms a Canon package is published for, by
// Go's names for them.
var canonPlatforms = map[string]string{
	"darwin/arm64": "darwin-arm64",
	"darwin/amd64": "darwin-x64",
	"linux/arm64":  "linux-arm64",
	"linux/amd64":  "linux-x64",
}

// Conformance runs the core's host conformance suite in an empty scratch
// directory. The suite prints its verdicts to standard output.
func (h *Host) Conformance(ctx context.Context, scratch string) (Outcome, error) {
	return h.run(ctx, map[string]any{"abi": effects.ABI, "conformance": scratch})
}

func (h *Host) run(ctx context.Context, invocation map[string]any) (Outcome, error) {
	request, err := json.Marshal(invocation)
	if err != nil {
		return Outcome{}, err
	}
	run := effects.New(effects.Options{Stdin: h.config.stdin, Stdout: h.config.stdout, Stderr: h.config.stderr})
	defer run.Close()
	ctx = context.WithValue(ctx, effectsKey{}, run)
	// Linear memory in a reserved mapping grows without copying and stays
	// outside Go's heap (memory_unix.go).
	ctx = experimental.WithMemoryAllocator(ctx, mappedAllocator)
	stdout, stderr := h.config.stdout, h.config.stderr
	if stdout == nil {
		stdout = os.Stdout
	}
	if stderr == nil {
		stderr = os.Stderr
	}
	// As in the Node host: the runtime's own WASI output reaches the
	// process's streams, real clocks and randomness, no preopens, no
	// environment, and argv ["lawspec"].
	module, err := h.runtime.InstantiateModule(ctx, h.compiled, wazero.NewModuleConfig().
		WithName("").
		WithArgs("lawspec").
		WithStdout(stdout).
		WithStderr(stderr).
		WithSysWalltime().
		WithSysNanotime().
		WithSysNanosleep().
		WithRandSource(rand.Reader).
		WithStartFunctions("_initialize"))
	if err != nil {
		return Outcome{}, fmt.Errorf("start the LawSpec core: %w", err)
	}
	defer module.Close(ctx)
	if _, err := module.ExportedFunction("lawspec_init").Call(ctx); err != nil {
		return Outcome{}, fmt.Errorf("start the LawSpec runtime: %w", err)
	}
	pointer, err := writeBuffer(ctx, module, request)
	if err != nil {
		return Outcome{}, err
	}
	results, err := module.ExportedFunction("lawspec_main").Call(ctx, uint64(pointer+4), uint64(len(request)))
	free(ctx, module, pointer)
	if err != nil {
		return Outcome{}, fmt.Errorf("run the LawSpec core: %w", err)
	}
	reply, err := readBuffer(module, uint32(results[0]))
	free(ctx, module, uint32(results[0]))
	if err != nil {
		return Outcome{}, err
	}
	var outcome Outcome
	if err := json.Unmarshal(reply, &outcome); err != nil {
		return Outcome{}, fmt.Errorf("the LawSpec core gave a malformed outcome: %w", err)
	}
	if outcome.Exit == nil && outcome.NotPorted == nil && outcome.Error == nil {
		return Outcome{}, fmt.Errorf("the LawSpec core gave no outcome: %s", reply)
	}
	return outcome, nil
}

// perform is the core's lawspec_host.perform import. It reads the request
// at (pointer, length), performs it, and returns a reply buffer allocated
// with lawspec_alloc, or 0 when it cannot.
func perform(ctx context.Context, module api.Module, pointer, length uint32) uint32 {
	run, ok := ctx.Value(effectsKey{}).(*effects.Effects)
	if !ok {
		return 0
	}
	view, ok := module.Memory().Read(pointer, length)
	if !ok {
		return 0
	}
	// The view aliases guest memory, which the reply allocation may grow.
	reply := run.Perform(append([]byte(nil), view...))
	buffer, err := writeBuffer(ctx, module, reply)
	if err != nil {
		return 0
	}
	return buffer
}

// writeBuffer copies bytes into a buffer from lawspec_alloc: a little-endian
// u32 length, then the bytes.
func writeBuffer(ctx context.Context, module api.Module, data []byte) (uint32, error) {
	results, err := module.ExportedFunction("lawspec_alloc").Call(ctx, uint64(len(data)+4))
	if err != nil {
		return 0, err
	}
	pointer := uint32(results[0])
	if pointer == 0 {
		return 0, errors.New("the LawSpec core is out of memory")
	}
	header := binary.LittleEndian.AppendUint32(nil, uint32(len(data)))
	if !module.Memory().Write(pointer, header) || !module.Memory().Write(pointer+4, data) {
		return 0, errors.New("a buffer from lawspec_alloc is outside memory")
	}
	return pointer, nil
}

func readBuffer(module api.Module, pointer uint32) ([]byte, error) {
	length, ok := module.Memory().ReadUint32Le(pointer)
	if !ok {
		return nil, errors.New("the LawSpec core returned a buffer outside memory")
	}
	view, ok := module.Memory().Read(pointer+4, length)
	if !ok {
		return nil, errors.New("the LawSpec core returned a buffer outside memory")
	}
	return append([]byte(nil), view...), nil
}

func free(ctx context.Context, module api.Module, pointer uint32) {
	module.ExportedFunction("lawspec_free").Call(ctx, uint64(pointer))
}
