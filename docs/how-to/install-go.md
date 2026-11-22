---
id: lawspec.how-to.install-go
kind: how-to
title: Install the Go host
---
# Install the Go host

The Go host is a pure-Go `lawspec` command. The LawSpec application itself
is the Haskell core, a WebAssembly module of over 100 MB that the Go module
does not carry: the first run downloads it ([First run](#first-run)). The host
runs it with [wazero](https://wazero.io) and only reads and writes files,
runs processes and talks to the terminal and network when the core asks it
to. See [host effects](../reference/host-effects.md#go-host).

## Requirements

- Go 1.25 or later. No C toolchain: the host does not use cgo.
- About 120 MB of disk for the downloaded core and about 330 MB for the
  compiled-code cache.
- Network access to the npm registry on the first run of a release, or a
  core of your own (`LAWSPEC_HOST_CORE`).

## Install a release

Install a release with:

```sh
go install goforge.dev/lawspec/cmd/lawspec@latest
```

Releases are tagged `hosts/go/vX.Y.Z` in the LawSpec repository; to pin
one, name its version, for example `@v0.36.3`.

## Install from a checkout

A command built from a checkout downloads the core its `pin.go` names, like a
release. To run a core built from the same checkout instead, build it and
name it with `LAWSPEC_HOST_CORE`; this needs the GHC WebAssembly toolchain
([ghc-wasm-meta](https://gitlab.haskell.org/haskell-wasm/ghc-wasm-meta)).

```sh
git clone https://github.com/brain-fuel/lawspec.git lawspec
cd lawspec
./tools/wasm-host-core.sh
(cd hosts/go && go install ./cmd/lawspec)
export LAWSPEC_HOST_CORE="$PWD/npm/host-core.wasm"
```

`LAWSPEC_HOST_CORE` is not checked against the pinned SHA-256: it is for a
core you built. `tools/hosts.sh go` builds the command into
`.artifacts/host-go/lawspec`.
`go install` puts `lawspec` in `$(go env GOBIN)`, or `$(go env GOPATH)/bin`
when `GOBIN` is unset; put that directory on your `PATH`.

## First run

```sh
lawspec fmt --check .
```

The first run of a release downloads its core, the npm package
`@goforgedev/core` at the same version, from `https://registry.npmjs.org`
(`LAWSPEC_CORE_REGISTRY` names another HTTPS registry, such as a mirror). The
host uses it only if its SHA-256 is the one the module records
(`hosts/go/internal/core/pin.go`), and keeps it in `lawspec/core/<version>`
under the user cache directory, so later runs need no network. A run with no
network and no kept core stops and says so.

It then compiles the core to machine code, on every processor,
which takes a few seconds (about 1.5 s on 18 cores, about 10 s on one).
The result, about 330 MB, is cached in `lawspec/wazero` under the user
cache directory (`~/Library/Caches` on macOS, `$XDG_CACHE_HOME` or
`~/.cache` on Linux), and later runs start in under a second. The cache keeps one entry
per core and wazero version; delete the directory to reclaim the space.

## Limit the compilation workers

Compiling the core uses as many goroutines as the process may use CPUs
(`runtime.GOMAXPROCS(0)`, which honours the `GOMAXPROCS` environment
variable, the CPU affinity mask and, on Linux, a container's cgroup CPU
limit). To leave CPUs for other work on a shared machine, cap it:

```sh
LAWSPEC_COMPILE_WORKERS=4 lawspec fmt --check .
```

The value is a whole number; 0 or less is the default. It matters only
when the core is compiled, that is when the cache has no entry for it. From
Go, pass `lawspec.WithCompilationWorkers(4)` to `lawspec.New`.

## Serve Learn

`lawspec learn` serves the Learn site from the npm package's resources
(its `learn/` folder, `core.wasm`, `core.wasm.gz` and `core_jsffi.js`),
which the Go host does not embed. The published npm package does not carry
`core.wasm.gz` yet, so point it at `npm/` in a compiler checkout, after
`node tools/learn-build.mjs` has built the assets:

```sh
LAWSPEC_RESOURCES="$PWD/npm" lawspec learn
```

Without it, `lawspec learn` reports that the Learn assets are missing.
From Go, pass `lawspec.WithResources(dir)` to `lawspec.New`. The server
listens on 127.0.0.1 only and stops on Ctrl-C.

## Run Canon

`lawspec project init` and `adopt` set Canon up with the grammar presets of
Rice's Tax 0.4.3, and `lawspec project status` and `validate` run Canon
0.2.5. Both come from a Canon bundle: the `canon` executable and a
`presets/` directory, which `tools/build-canon.sh` builds in a compiler
checkout (into `.artifacts/canon/<platform>`). Point the host at it:

```sh
tools/build-canon.sh
LAWSPEC_CANON="$PWD/.artifacts/canon/darwin-arm64" lawspec project init
```

From Go, pass `lawspec.WithCanon(dir)` to `lawspec.New`.

Without a bundle, the Go host downloads Canon when a project command first
needs it: this release's `@goforgedev/canon-<platform>` package from the
npm registry, which LawSpec checks against the SHA-256 it records before
unpacking it into `lawspec/canon/<version>/<platform>` in the user cache
directory (`os.UserCacheDir`). Later runs use that copy. To take the
package from a mirror, set `LAWSPEC_CANON_REGISTRY` to the registry's
base URL; the digest still has to match. On a platform without a package,
or in a build that records no digest for it, `project init` and `adopt`
fail before writing anything in a project without `canon.yaml`, and
`status` and `validate` report Canon `incomplete` unless `CANON` names a
matching `canon` executable.

## Exit codes

| Code | Meaning |
| --- | --- |
| 0, 1, 2 | The command's own exit code, as with the npm CLI. |
| 1 | The host could not start the core, the core refused the invocation, or `LAWSPEC_COMPILE_WORKERS` is not a whole number. |
| 69 | The command is not ported to the core yet. |

## Use it from Go

The module's root package runs an invocation programmatically:

```go
host, err := lawspec.New(ctx)
if err != nil {
	return err
}
defer host.Close(ctx)
outcome, err := host.Main(ctx, []string{"fmt", "--check", "."}, dir)
```

`outcome.Exit`, `outcome.NotPorted` or `outcome.Error` is set. Options set
the compilation cache directory, the compilation workers, the standard
streams, or another core module.
