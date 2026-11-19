// Command conformance runs the core's host conformance suite
// (LawSpec.Host.Conformance) over the Go host:
//
//	go run ./internal/cmd/conformance <empty scratch directory>
//
// The suite and its expectations live in the core, so every host runs the
// same one. LAWSPEC_HOST_CORE names a core module to run instead of this
// release's, which is otherwise downloaded and verified (lawspec.New).
// ref:DEC-host-effect-abi
package main

import (
	"context"
	"fmt"
	"os"
	"path/filepath"

	"goforge.dev/lawspec"
)

func main() {
	if len(os.Args) != 2 {
		fmt.Fprintln(os.Stderr, "usage: conformance <empty scratch directory>")
		os.Exit(2)
	}
	os.Exit(run(os.Args[1]))
}

func run(scratch string) int {
	ctx := context.Background()
	scratch, err := filepath.Abs(scratch)
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		return 1
	}
	var options []lawspec.Option
	if path := os.Getenv("LAWSPEC_HOST_CORE"); path != "" {
		wasm, err := os.ReadFile(path)
		if err != nil {
			fmt.Fprintln(os.Stderr, err)
			return 1
		}
		options = append(options, lawspec.WithCore(wasm))
	}
	host, err := lawspec.New(ctx, options...)
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		return 1
	}
	defer host.Close(ctx)
	outcome, err := host.Conformance(ctx, scratch)
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		return 1
	}
	if outcome.Exit == nil {
		return 1
	}
	return *outcome.Exit
}
