// Command lawspec is the LawSpec CLI on the Go host: it sends its arguments
// and working directory to the core and exits with the core's exit
// code. Go has no legacy CLI to fall back to, so a command the core has not
// ported yet ends with exit code 69 (EX_UNAVAILABLE in sysexits.h) and a
// message saying so. The core is this release's, downloaded and verified
// into the user cache directory on first use (lawspec.New;
// LAWSPEC_CORE_REGISTRY names another HTTPS npm registry to take it from).
// LAWSPEC_HOST_CORE names a core module to run instead, unchecked (a core
// built from source), LAWSPEC_COMPILE_WORKERS, a whole number, caps the
// goroutines that compile it (0 or less, or unset, is every CPU the process
// may use), LAWSPEC_RESOURCES names the package resources directory
// (lawspec learn's assets; lawspec.WithResources), and LAWSPEC_CANON the
// Canon bundle lawspec project runs (lawspec.WithCanon). Without
// LAWSPEC_CANON the core downloads and verifies this release's Canon
// package into the user cache directory when a project command needs it;
// LAWSPEC_CANON_REGISTRY names another npm registry to take it from.
// ref:DEC-host-effect-abi ref:DEC-native-canon ref:DEC-go-core-download
package main

import (
	"context"
	"fmt"
	"os"
	"runtime/debug"
	"strconv"

	"goforge.dev/lawspec"
)

// notPortedExit is the exit code for a command the core does not run yet.
const notPortedExit = 69

func main() {
	os.Exit(run())
}

func run() int {
	ctx := context.Background()
	var options []lawspec.Option
	if path := os.Getenv("LAWSPEC_HOST_CORE"); path != "" {
		wasm, err := os.ReadFile(path)
		if err != nil {
			fmt.Fprintf(os.Stderr, "lawspec: %v\n", err)
			return 1
		}
		options = append(options, lawspec.WithCore(wasm))
	}
	if text := os.Getenv("LAWSPEC_COMPILE_WORKERS"); text != "" {
		workers, err := strconv.Atoi(text)
		if err != nil {
			fmt.Fprintf(os.Stderr, "lawspec: LAWSPEC_COMPILE_WORKERS must be a whole number, not %q\n", text)
			return 1
		}
		options = append(options, lawspec.WithCompilationWorkers(workers))
	}
	if dir := os.Getenv("LAWSPEC_RESOURCES"); dir != "" {
		options = append(options, lawspec.WithResources(dir))
	}
	if dir := os.Getenv("LAWSPEC_CANON"); dir != "" {
		options = append(options, lawspec.WithCanon(dir))
	}
	cwd, err := workingDirectory()
	if err != nil {
		fmt.Fprintf(os.Stderr, "lawspec: %v\n", err)
		return 1
	}
	host, err := lawspec.New(ctx, options...)
	if err != nil {
		fmt.Fprintf(os.Stderr, "lawspec: %v\n", err)
		return 1
	}
	defer host.Close(ctx)
	// Decoding and validating the core leaves garbage in Go's heap that the
	// collector would otherwise hand back to the system only gradually;
	// returning it now lowers the command's peak resident memory.
	debug.FreeOSMemory()
	outcome, err := host.Main(ctx, os.Args[1:], cwd)
	switch {
	case err != nil:
		fmt.Fprintf(os.Stderr, "lawspec: %v\n", err)
		return 1
	case outcome.Exit != nil:
		return *outcome.Exit
	case outcome.NotPorted != nil:
		fmt.Fprintf(os.Stderr, "lawspec: %s\nThe Go host runs only the commands ported to the LawSpec core; use the npm package for the others.\n", *outcome.NotPorted)
		return notPortedExit
	default:
		fmt.Fprintf(os.Stderr, "lawspec: %s\n", outcome.Error.Message)
		return 1
	}
}
