// Package core finds the LawSpec host-effect core, the plain WASI reactor
// tools/wasm-host-core.sh builds. The module is over 100 MB, so the Go module
// does not carry it: the first run downloads this release's
// @goforgedev/core npm package, checks the core inside it against the
// SHA-256 recorded in pin.go, and keeps it in the user cache directory.
// This is the one thing the Go host does before the core runs, so it cannot
// be the core's; it holds no other logic. ref:DEC-go-core-download
package core

import (
	"archive/tar"
	"compress/gzip"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"strings"
)

// DefaultRegistry is the npm registry @goforgedev/core is published to.
const DefaultRegistry = "https://registry.npmjs.org"

// RegistryEnvironment names another HTTPS registry (a mirror) to download
// from.
const RegistryEnvironment = "LAWSPEC_CORE_REGISTRY"

// member is the core's path inside the package tarball.
const member = "package/host-core.wasm"

// maxCore bounds what is read from the tarball for the core: a larger
// member cannot be the recorded one.
const maxCore = 1 << 30

// Source says where Load looks and downloads.
type Source struct {
	// Cache is the user cache directory (os.UserCacheDir); the core is kept
	// at lawspec/core/<Version>/host-core.wasm under it.
	Cache string
	// Registry is the npm registry; DefaultRegistry when empty. It must be
	// an https URL.
	Registry string
	// Client downloads; http.DefaultClient when nil.
	Client *http.Client
}

// URL is a release's package tarball address in a registry.
func URL(registry, version string) string {
	if registry == "" {
		registry = DefaultRegistry
	}
	return strings.TrimRight(registry, "/") + "/@goforgedev/core/-/core-" + version + ".tgz"
}

// Path is where a release's verified core is kept under a cache directory.
func Path(cache, version string) string {
	return filepath.Join(cache, "lawspec", "core", version, "host-core.wasm")
}

// Load returns this release's core: the cached copy when it matches the
// recorded SHA-256, otherwise a fresh download, checked and then cached.
func Load(ctx context.Context, source Source) ([]byte, error) {
	return load(ctx, source, Version, SHA256)
}

func load(ctx context.Context, source Source, version, expected string) ([]byte, error) {
	if source.Cache == "" {
		return nil, errors.New("no user cache directory to keep the LawSpec core in; set LAWSPEC_HOST_CORE to a host-core.wasm")
	}
	file := Path(source.Cache, version)
	if wasm, err := os.ReadFile(file); err == nil && digest(wasm) == expected {
		return wasm, nil
	}
	registry := source.Registry
	if registry == "" {
		registry = DefaultRegistry
	}
	if !strings.HasPrefix(registry, "https://") {
		return nil, fmt.Errorf("%s must be an https URL, not %q", RegistryEnvironment, registry)
	}
	url := URL(registry, version)
	wasm, err := download(ctx, source.Client, url)
	if err != nil {
		return nil, fmt.Errorf("download the LawSpec core %s from %s: %w (set LAWSPEC_HOST_CORE to a host-core.wasm to run without the network)", version, url, err)
	}
	if actual := digest(wasm); actual != expected {
		return nil, fmt.Errorf("LawSpec core SHA-256 mismatch: %s holds %s, but this build of LawSpec records %s", url, actual, expected)
	}
	if err := keep(file, wasm); err != nil {
		return nil, fmt.Errorf("keep the LawSpec core in %s: %w", file, err)
	}
	return wasm, nil
}

// download fetches the tarball and returns the core inside it.
func download(ctx context.Context, client *http.Client, url string) ([]byte, error) {
	if client == nil {
		client = http.DefaultClient
	}
	request, err := http.NewRequestWithContext(ctx, http.MethodGet, url, nil)
	if err != nil {
		return nil, err
	}
	response, err := client.Do(request)
	if err != nil {
		return nil, err
	}
	defer response.Body.Close()
	if response.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("the registry answered %s", response.Status)
	}
	return extract(response.Body)
}

// extract reads the core out of a gzipped npm package tarball.
func extract(r io.Reader) ([]byte, error) {
	unzipped, err := gzip.NewReader(r)
	if err != nil {
		return nil, err
	}
	archive := tar.NewReader(unzipped)
	for {
		header, err := archive.Next()
		if errors.Is(err, io.EOF) {
			return nil, fmt.Errorf("the package holds no %s", member)
		}
		if err != nil {
			return nil, err
		}
		if header.Name != member || header.Typeflag != tar.TypeReg {
			continue
		}
		if header.Size > maxCore {
			return nil, fmt.Errorf("the package's %s is %d bytes", member, header.Size)
		}
		return io.ReadAll(io.LimitReader(archive, maxCore))
	}
}

// keep writes the core atomically: a temporary sibling, then a rename.
func keep(file string, wasm []byte) error {
	if err := os.MkdirAll(filepath.Dir(file), 0o755); err != nil {
		return err
	}
	temporary, err := os.CreateTemp(filepath.Dir(file), ".host-core-*.wasm")
	if err != nil {
		return err
	}
	defer os.Remove(temporary.Name())
	if _, err := temporary.Write(wasm); err != nil {
		temporary.Close()
		return err
	}
	if err := temporary.Close(); err != nil {
		return err
	}
	return os.Rename(temporary.Name(), file)
}

func digest(bytes []byte) string {
	sum := sha256.Sum256(bytes)
	return hex.EncodeToString(sum[:])
}
