---
id: lawspec.how-to.build-native
kind: how-to
title: Build the native binaries
---
# Build the native binaries

The JVM packages carry the natively compiled `lawspec` (stack's
`lawspec-native`) and the Canon bundle `tools/build-canon.sh` builds (the
`canon` executable and Rice's Tax's presets) for four platforms:
`darwin-arm64`, `darwin-x64`, `linux-arm64` and `linux-x64`. GHC builds an
executable only for the platform it runs on, so each binary comes from a
build on that platform, real or emulated. `tools/build-native.sh` builds all
four on one Apple Silicon Mac.

## Requirements

- An Apple Silicon Mac with stack (the `darwin-arm64` build uses it).
- For the Linux builds, podman with a running machine
  (`podman machine start`). The script neither starts nor stops it.
- For `darwin-x64`, Rosetta 2
  (`softwareupdate --install-rosetta --agree-to-license`, as an
  administrator).

## Build

```sh
for p in linux-arm64 linux-x64 darwin-x64 darwin-arm64; do
  tools/build-native.sh --platform $p
  tools/build-native.sh --platform $p --canon
done
```

Each build compiles the committed tree at `--rev` (default `HEAD`) from
`git archive`, never the work tree, and leaves in
`.artifacts/native-build/<platform>/`:

| File | Contents |
| --- | --- |
| `lawspec-native` | the stripped executable |
| `ghc.txt` | the GHC and stack versions that built it |
| `dependencies.txt` | `stack ls dependencies`, before the build |
| `linkage.txt` | `file`, then `readelf -d` and `ldd` (Linux) or `otool -L` (macOS) |
| `build.txt` | the commit, the target and the build's duration |
| `canon/` | with `--canon`: the Canon bundle (`canon`, `canon.sha256`, `canon.json`, `presets/`) |
| `canon-linkage.txt`, `canon-build.txt` | with `--canon`: its linkage check and build record |

With `--canon` the build runs `tools/build-canon.sh` from the same revision
in the same environment, with the same static link. It clones canon and Rice's
Tax at their pinned commits from GitHub, or from `CANON_SOURCE` and
`RICESTAX_SOURCE` when they are set (Git URLs for the Linux builds, which run
in a container).

Options: `--jobs N` (stack's parallel package builds, default 2), `--cpus N`
(the container's CPU limit, default 4), `--image NAME`, `--out DIR`, and
`--project DIR`, `--target PACKAGE:exe:NAME` and `--exe NAME` to build another
stack project's executable on the same toolchains.

### Linux: fully static, against musl

Both Linux builds run in the image `tools/native/Containerfile` describes:
Alpine (musl) with GHC 9.10.3's Alpine bindist, stack 3.11.1 and the static
libraries, plus Git and `shasum` for `tools/build-canon.sh`. The base image is pinned by digest and GHC's and stack's archives
by SHA-256. The script builds the image the first time
(`localhost/lawspec-native-toolchain:ghc-9.10.3-arm64`, `-amd64`) and keeps
it, and keeps each architecture's stack package cache in the podman volume
`lawspec-native-stack-<arch>`. The build container itself is removed when the
build ends, whether it succeeded or not.

The executable is linked with Cabal's `--enable-executable-static` (stack's
`configure-options` for the local packages, set in the build container only):
musl's libc, GMP and libffi are all inside it. The build fails unless
`readelf` finds neither a dynamic section nor a program interpreter. A fully
static executable has no glibc version floor and no shared libraries to find,
so one binary per architecture runs on any Linux distribution, glibc or musl,
old or new.

The alternative, a glibc build on an old Debian or Ubuntu LTS, would still
need GMP and libffi forced static by hand, and would run only on
distributions whose glibc is at least as new as the build's.

`linux-x64` runs in an amd64 container under the podman machine's QEMU
emulation. It takes hours rather than minutes; hold `caffeinate` while it
runs.

### darwin-x64: under Rosetta

The script downloads stack's x86-64 macOS release (checked by SHA-256) into
`.tools/darwin-x64/` (ignored by git) and runs it under `arch -x86_64` with
`STACK_ROOT=.tools/darwin-x64/stack-root`, a `PATH` of system directories
only, and `system-ghc: false`. stack installs the x86-64 GHC 9.10.3 there.
Nothing touches `~/.stack`, `~/.ghcup` or the arm64 toolchain. GHC's macOS
builds keep GMP inside the runtime, and libffi and libiconv are the system's,
so the build fails if `otool -L` finds a library outside `/usr/lib` or
`/System/Library`.

## Check the dependency versions

Every build must resolve the same libraries as the `darwin-arm64` build,
which `lawspec-dev dependencies --check` holds to `wasm/cabal.project.freeze`:

```sh
for p in darwin-x64 linux-arm64 linux-x64; do
  diff .artifacts/native-build/darwin-arm64/dependencies.txt .artifacts/native-build/$p/dependencies.txt
done
```

## Stage

```sh
for p in darwin-arm64 darwin-x64 linux-arm64 linux-x64; do
  hosts/jvm/stage-native.sh --platform $p \
    --binary .artifacts/native-build/$p/lawspec-native --canon .artifacts/native-build/$p/canon
done
hosts/jvm/stage-native.sh --check-all
```

`stage-native.sh` checks each executable's format and records its SHA-256 and
size in `.artifacts/jvm/natives/natives.properties`, the manifest the launcher
jar carries. The binaries, the bundles and the manifest are build outputs and
stay out of git.

## Pack Canon for npm and record the digests

```sh
for p in darwin-arm64 darwin-x64 linux-arm64 linux-x64; do
  tools/package-canon.sh --platform $p --bundle .artifacts/native-build/$p/canon
done
stack exec lawspec-dev -- canon-packages --record
```

`package-canon.sh` packs each bundle as `@goforgedev/canon-<platform>` into
`.artifacts/canon-npm/`. `canon-packages --record` writes each archive's
SHA-256 into `src/LawSpec/App/CanonPackages.hs`, which the core compiles in:
the Go host downloads this release's archive and refuses any other bytes. So
record before `make wasm` and the native builds, publish these archives
exactly as packed, and never repack after recording; `lawspec-dev integrity`
fails when a packed archive differs from its record.

The Go host's core is pinned the other way round: `make wasm` records the
built core's own SHA-256 in `hosts/go/internal/core/pin.go`, and
`tools/package-core.sh` then packs that core as `@goforgedev/core`
([Release LawSpec](release.md#5-pack-and-inspect)).

## Smoke-test

```sh
tools/native/smoke-native.sh --platform linux-x64 \
  --binary .artifacts/native-build/linux-x64/lawspec-native --canon .artifacts/native-build/linux-x64/canon
```

The smoke test runs the binary's `--version`, its host conformance suite, and
`init --target yaml`, `fmt`, `fmt --check`, `check` and `generate` in a new
project. A Linux binary runs in a clean Debian container of its architecture,
with no GHC in it, so the conformance suite reports its two `serve` checks as
unsupported (they need `curl`). `darwin-x64` runs under `arch -x86_64`.

With `--canon` it also runs `canon version`, then `lawspec project init
--languages python,folio` with `LAWSPEC_CANON` naming the bundle, which sets
Canon up from the bundle's presets, then `canon files` and `canon check` on
that project with a one-function Python module. The check must fail with
exactly one finding, the function's missing canonical comment, which shows
the interpreted Python grammar parsed it. (Canon also notes that it cannot
ask Git about the file; the clean container has no Git.)

## Compare with the darwin-arm64 build

```sh
tools/native/parity-native.sh --platform linux-arm64 \
  --binary .artifacts/native-build/linux-arm64/lawspec-native \
  --reference .artifacts/native-build/darwin-arm64/lawspec-native
```

For each of `examples/specs/*.lawspec`, in a project of its own, `fmt --check`,
`check` and `generate` must produce the same standard output, standard error,
exit code and files as the `darwin-arm64` build. The Linux run uses the same
absolute paths as the reference, so messages that name a path compare equal.
`.lawspec/cache` is left out, since its folders are keyed by the build.
`--only <glob>` picks specs by name. This is a subset of `tools/hosts.sh
parity`, which also needs the host-effect core and the npm CLI.

## Clean up

```sh
podman machine stop
```

To reclaim the space, remove the images and the package caches:
`podman rmi localhost/lawspec-native-toolchain:ghc-9.10.3-arm64 localhost/lawspec-native-toolchain:ghc-9.10.3-amd64`
and `podman volume rm lawspec-native-stack-arm64 lawspec-native-stack-amd64`.
The next build recreates them.
