#!/usr/bin/env bash
# Builds a native executable of a stack project for one platform from a
# committed revision, on an Apple Silicon Mac: the JVM platform jars'
# lawspec-native by default, LawSpec's Canon bundle with --canon, or another
# stack project's executable on the same toolchains.
#   tools/build-native.sh --platform <platform> [--canon] [options]
# Platforms and how each is built:
#   linux-arm64   in an arm64 Alpine container (tools/native/Containerfile),
#                 fully static against musl
#   linux-x64     the same in an amd64 container, under the podman machine's
#                 x86-64 emulation (hours, not minutes)
#   darwin-x64    an x86-64 GHC and stack under Rosetta (arch -x86_64), from
#                 an isolated toolchain in .tools/darwin-x64 that never
#                 touches ~/.stack or ~/.ghcup
#   darwin-arm64  this Mac's own stack and GHC
# Options:
#   --canon           build the Canon bundle (tools/build-canon.sh at --rev)
#                     instead, into <out>/canon, with canon-linkage.txt and
#                     canon-build.txt; CANON_SOURCE and RICESTAX_SOURCE, when
#                     set, pass through (a container needs Git URLs)
#   --project <dir>   the stack project (default: this repository)
#   --rev <rev>       the git revision to build (default: HEAD); the build
#                     sees exactly the committed tree, never the work tree
#   --target <t>      the stack target (default: lawspec:exe:lawspec-native)
#   --exe <name>      the executable it installs (default: lawspec-native)
#   --out <dir>       where the results go (default:
#                     .artifacts/native-build/<platform> in this repository)
#   --jobs <n>        stack's parallel package builds (default: 2)
#   --cpus <n>        the container's CPU limit (default: 4)
#   --image <name>    the toolchain image (default:
#                     localhost/lawspec-native-toolchain:ghc-9.10.3-<arch>,
#                     built from tools/native/Containerfile when missing)
# Results in the output directory: the stripped executable (or the Canon
# bundle), ghc.txt (the
# toolchain's versions), dependencies.txt (stack ls dependencies, which must
# match the darwin-arm64 build's: tools/build-native.sh --platform
# darwin-arm64 records it too), linkage.txt (file, readelf/ldd or otool) and
# build.txt (revision and timings).
# The Linux builds need the podman machine running; the script neither starts
# nor stops it. Each build's container is removed when it ends, however it
# ends; the image and the per-architecture stack package cache (volume
# lawspec-native-stack-<arch>) are kept for the next build.
# See docs/how-to/build-native.md. ref:DEC-jvm-native-host
set -euo pipefail
repository="$(cd "$(dirname "$0")/.." && pwd)"

ghc_version=9.10.3
stack_version=3.11.1
stack_sha256_osx_x86_64=603db63eef6246b02dd042e446686f61e3410ee9ef73cb3838314e24468fb290
# The oldest macOS the darwin builds run on. clang reads
# MACOSX_DEPLOYMENT_TARGET for every C file and link, so each darwin build
# exports it and compiles every dependency in a Stack root of its own for
# this target: Stack's snapshot cache is not keyed by it, so libraries
# compiled for another target would otherwise be reused. darwin_linkage
# checks the result.
macos_target="${LAWSPEC_MACOS_TARGET:-13.0}"

platform=""
project="$repository"
rev=HEAD
target=lawspec:exe:lawspec-native
exe=lawspec-native
out=""
jobs=2
cpus=4
image=""
canon=false

usage()
{
  sed -n '2,/^# See docs/p' "$0" | sed 's/^# \{0,1\}//' >&2
  exit 2
}

while [ $# -gt 0 ]; do
  case "$1" in
    --platform) platform="${2:?--platform needs a platform}"; shift 2 ;;
    --canon) canon=true; shift ;;
    --project) project="$(cd "${2:?--project needs a directory}" && pwd)"; shift 2 ;;
    --rev) rev="${2:?--rev needs a revision}"; shift 2 ;;
    --target) target="${2:?--target needs a stack target}"; shift 2 ;;
    --exe) exe="${2:?--exe needs a name}"; shift 2 ;;
    --out) out="${2:?--out needs a directory}"; shift 2 ;;
    --jobs) jobs="${2:?--jobs needs a number}"; shift 2 ;;
    --cpus) cpus="${2:?--cpus needs a number}"; shift 2 ;;
    --image) image="${2:?--image needs an image name}"; shift 2 ;;
    -h | --help) usage ;;
    *) echo "build-native: unknown argument $1" >&2; usage ;;
  esac
done
[ -n "$platform" ] || usage
[ -n "$out" ] || out="$repository/.artifacts/native-build/$platform"
mkdir -p "$out"
out="$(cd "$out" && pwd)"
commit="$(git -C "$project" rev-parse --verify "$rev^{commit}")"
if $canon; then
  built=canon/canon
  linkage_name=canon-linkage.txt
  record_name=canon-build.txt
else
  built="$exe"
  linkage_name=linkage.txt
  record_name=build.txt
fi
started="$(date +%s)"

record()
{
  local finished
  finished="$(date +%s)"
  {
    echo "platform=$platform"
    echo "project=$project"
    echo "commit=$commit"
    if $canon; then echo "target=canon"; else echo "target=$target"; fi
    echo "started=$(date -u -r "$started" +%Y-%m-%dT%H:%M:%SZ)"
    echo "seconds=$((finished - started))"
  } >"$out/$record_name"
  echo "build-native: $platform built in $((finished - started))s: $out/$built"
}

build_linux()
{
  local arch="$1" container
  command -v podman >/dev/null || { echo "build-native: podman is required for $platform" >&2; exit 1; }
  podman info >/dev/null 2>&1 || { echo "build-native: podman is not running (podman machine start)" >&2; exit 1; }
  [ -n "$image" ] || image="localhost/lawspec-native-toolchain:ghc-$ghc_version-$arch"
  if ! podman image exists "$image"; then
    podman build --platform "linux/$arch" -t "$image" -f "$repository/tools/native/Containerfile" "$repository/tools/native"
  fi
  container="lawspec-native-build-$platform-$$"
  # The container goes whatever happens to the build; the cache volume stays.
  trap 'podman rm -f "$container" >/dev/null 2>&1 || true' EXIT
  # The build script comes from this checkout, not the image, so a fix to it
  # needs no image rebuild.
  local -a step=(--target "$target" --exe "$exe" --jobs "$jobs") pass=()
  if $canon; then
    step=(--canon "$platform" --jobs "$jobs")
    [ -z "${CANON_SOURCE:-}" ] || pass+=(-e "CANON_SOURCE=$CANON_SOURCE")
    [ -z "${RICESTAX_SOURCE:-}" ] || pass+=(-e "RICESTAX_SOURCE=$RICESTAX_SOURCE")
  fi
  podman create -i --name "$container" --platform "linux/$arch" --cpus "$cpus" \
    -v "lawspec-native-stack-$arch:/stack-root" ${pass[@]+"${pass[@]}"} \
    --entrypoint /bin/bash "$image" /usr/local/bin/build-native-run.sh "${step[@]}" >/dev/null
  podman cp "$repository/tools/native/build-in-container.sh" "$container:/usr/local/bin/build-native-run.sh"
  local status=0
  git -C "$project" archive --format=tar "$commit" | podman start -ai "$container" || status=$?
  # Whatever the build left, its logs included, comes out even on failure.
  podman cp "$container:/out/." "$out/" 2>/dev/null || true
  podman rm -f "$container" >/dev/null
  trap - EXIT
  [ "$status" -eq 0 ] || { echo "build-native: the $platform build failed ($status)" >&2; exit "$status"; }
}

# The x86-64 toolchain under Rosetta: stack's own x86-64 binary, with a
# STACK_ROOT of its own, installs the x86-64 GHC there. PATH holds only the
# system's tools, so nothing arm64-only (Homebrew) is found.
build_darwin_x64()
{
  [ "$(uname -s)-$(uname -m)" = "Darwin-arm64" ] || { echo "build-native: darwin-x64 is built on an Apple Silicon Mac under Rosetta" >&2; exit 1; }
  arch -x86_64 /usr/bin/true 2>/dev/null || { echo "build-native: Rosetta is not installed (softwareupdate --install-rosetta)" >&2; exit 1; }
  local tools="$repository/.tools/darwin-x64"
  local stack="$tools/bin/stack"
  if [ ! -x "$stack" ]; then
    local archive="stack-$stack_version-osx-x86_64.tar.gz"
    mkdir -p "$tools/download" "$tools/bin"
    curl -fsSLo "$tools/download/$archive" "https://github.com/commercialhaskell/stack/releases/download/v$stack_version/$archive"
    echo "$stack_sha256_osx_x86_64  $tools/download/$archive" | shasum -a 256 -c -
    tar -xzf "$tools/download/$archive" -C "$tools/download"
    install -m 755 "$tools/download/stack-$stack_version-osx-x86_64/stack" "$stack"
  fi
  local root="$tools/stack-root-macos-$macos_target"
  mkdir -p "$root"
  # Never a system GHC: /opt/homebrew's or ghcup's is arm64.
  printf 'system-ghc: false\ninstall-ghc: true\n' >"$root/config.yaml"
  local source="$tools/src"
  rm -rf "$source"
  mkdir -p "$source"
  git -C "$project" archive --format=tar "$commit" | tar -x -C "$source"
  local -a x64=(arch -x86_64 /usr/bin/env -i HOME="$HOME" STACK_ROOT="$root" MACOSX_DEPLOYMENT_TARGET="$macos_target" PATH="$tools/bin:/usr/bin:/bin:/usr/sbin:/sbin" LANG=en_US.UTF-8 TMPDIR="${TMPDIR:-/tmp}")
  if $canon; then
    # build-canon.sh finds the x86-64 stack first on PATH.
    (cd "$source" && "${x64[@]}" ${CANON_SOURCE:+CANON_SOURCE="$CANON_SOURCE"} ${RICESTAX_SOURCE:+RICESTAX_SOURCE="$RICESTAX_SOURCE"} \
      CANON_BUILD="$tools/canon-build" /bin/bash tools/build-canon.sh --platform darwin-x64 --out "$out/canon")
    darwin_linkage
    return
  fi
  (
    cd "$source"
    {
      "${x64[@]}" "$stack" --no-terminal exec -- ghc --version
      "${x64[@]}" "$stack" --version
    } >"$out/ghc.txt"
    "${x64[@]}" "$stack" --no-terminal ls dependencies >"$out/dependencies.txt"
    "${x64[@]}" "$stack" --no-terminal build "$target" --jobs "$jobs"
    cp "$("${x64[@]}" "$stack" --no-terminal path --local-install-root)/bin/$exe" "$out/$exe"
  )
  strip "$out/$exe"
  darwin_linkage
}

build_darwin_arm64()
{
  [ "$(uname -s)-$(uname -m)" = "Darwin-arm64" ] || { echo "build-native: darwin-arm64 is built on an Apple Silicon Mac" >&2; exit 1; }
  local tools="$repository/.tools/darwin-arm64"
  local source="$tools/src"
  # A Stack root of its own, for this deployment target (see macos_target);
  # it installs its own GHC rather than reuse one built into another root.
  export STACK_ROOT="$tools/stack-root-macos-$macos_target"
  export MACOSX_DEPLOYMENT_TARGET="$macos_target"
  mkdir -p "$STACK_ROOT"
  printf 'system-ghc: false\ninstall-ghc: true\n' >"$STACK_ROOT/config.yaml"
  rm -rf "$source"
  mkdir -p "$source"
  git -C "$project" archive --format=tar "$commit" | tar -x -C "$source"
  if $canon; then
    (cd "$source" && CANON_BUILD="$repository/.tools/darwin-arm64/canon-build" tools/build-canon.sh --platform darwin-arm64 --out "$out/canon")
    darwin_linkage
    return
  fi
  (
    cd "$source"
    {
      stack --no-terminal exec -- ghc --version
      stack --version
    } >"$out/ghc.txt"
    stack --no-terminal ls dependencies >"$out/dependencies.txt"
    stack --no-terminal build "$target" --jobs "$jobs"
    cp "$(stack --no-terminal path --local-install-root)/bin/$exe" "$out/$exe"
  )
  strip "$out/$exe"
  darwin_linkage
}

# Only system libraries (/usr/lib, /System) may be linked: GHC's macOS
# builds carry GMP in the runtime, and libffi and libiconv are the system's.
darwin_linkage()
{
  local executable="$out/$built" name
  name="$(basename "$executable")"
  {
    echo "\$ file $name"
    file "$executable"
    echo
    echo "\$ otool -L $name"
    otool -L "$executable"
  } >"$out/$linkage_name"
  local minos
  minos="$(otool -l "$executable" | awk '/LC_BUILD_VERSION/ { found = 1 } found && $1 == "minos" { print $2; exit }')"
  echo "minimum macOS: $minos" >>"$out/$linkage_name"
  if [ "$minos" != "$macos_target" ]; then
    echo "build-native: $name requires macOS $minos, not $macos_target" >&2
    exit 1
  fi
  if otool -L "$executable" | tail -n +2 | grep -Ev '^[[:space:]]+(/usr/lib/|/System/Library/)' | grep -q .; then
    echo "build-native: $name links a library outside the system:" >&2
    cat "$out/$linkage_name" >&2
    exit 1
  fi
}

case "$platform" in
  linux-arm64) build_linux arm64 ;;
  linux-x64) build_linux amd64 ;;
  darwin-x64) build_darwin_x64 ;;
  darwin-arm64) build_darwin_arm64 ;;
  *) echo "build-native: unknown platform $platform (darwin-arm64, darwin-x64, linux-arm64, linux-x64)" >&2; exit 2 ;;
esac
record
