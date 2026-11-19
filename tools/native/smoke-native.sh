#!/usr/bin/env bash
# Smoke-tests a built lawspec-native, and its Canon bundle, where they will
# run, without GHC:
#   tools/native/smoke-native.sh --platform <platform> --binary <path> [--canon <bundle>]
# linux-arm64 and linux-x64 run in a clean Debian container of that
# architecture (removed afterwards); darwin-x64 runs under arch -x86_64;
# darwin-arm64 runs directly. The checks: --version, the host conformance
# suite, and fmt, fmt --check, check and generate of the YAML project init
# creates (a target with no toolchain to install). With a Canon bundle:
# canon version, lawspec project init with that bundle (LAWSPEC_CANON),
# which sets Canon up for Python and Folio from its presets, then canon
# files and canon check on that project with a small Python module in it
# (parsed with the presets' interpreted Python grammar), which must report
# its missing canonical comment. The container needs the podman machine
# running; the script neither starts nor stops it.
# See docs/how-to/build-native.md.
set -euo pipefail
# A glibc distribution with no Haskell toolchain, pinned by digest.
debian=docker.io/library/debian:bookworm-slim@sha256:734a72b3d6142a71993b4bc580ca01d8ca687f77a2c422d96a961d3376b179bc

usage()
{
  echo "usage: smoke-native.sh --platform <platform> --binary <path> [--canon <bundle>]" >&2
  exit 2
}

platform=""
binary=""
canon=""
while [ $# -gt 0 ]; do
  case "$1" in
    --platform) platform="${2:?--platform needs a platform}"; shift 2 ;;
    --binary) binary="${2:?--binary needs a path}"; shift 2 ;;
    --canon) canon="${2:?--canon needs a bundle directory}"; shift 2 ;;
    *) usage ;;
  esac
done
[ -n "$platform" ] && [ -f "$binary" ] || usage
[ -z "$canon" ] || [ -x "$canon/canon" ] || { echo "smoke-native: no canon executable in $canon" >&2; exit 2; }

# The checks, as a POSIX shell script run where the binary runs, with the
# binary as $1 and the Canon bundle, if any, as $2.
checks='
set -eu
lawspec="$1"
canon="${2:-}"
echo "== --version"
"$lawspec" --version
scratch="$(mktemp -d)"
mkdir "$scratch/conformance" "$scratch/project" "$scratch/canon-project"
echo "== --host-conformance"
"$lawspec" --host-conformance "$scratch/conformance" </dev/null
cd "$scratch/project"
echo "== init"
"$lawspec" init --target yaml </dev/null
# The starter spec from init is not in canonical layout (on every platform),
# so fmt rewrites it first and --check then confirms the result is stable.
echo "== fmt"
"$lawspec" fmt </dev/null
echo "== fmt --check"
"$lawspec" fmt --check </dev/null
echo "== check"
"$lawspec" check </dev/null
echo "== generate"
"$lawspec" generate </dev/null
if [ -n "$canon" ]; then
  echo "== canon version"
  "$canon/canon" version
  cd "$scratch/canon-project"
  echo "== project init --languages python,folio (LAWSPEC_CANON)"
  LAWSPEC_CANON="$canon" "$lawspec" project init --languages python,folio </dev/null
  printf "def add(a, b):\n    return a + b\n" >adder.py
  echo "== canon files"
  "$canon/canon" files </dev/null
  # The module has no canonical comment, so check must fail with exactly
  # that finding: the grammar parsed it and the rule ran.
  echo "== canon check (expects one finding)"
  status=0
  findings="$("$canon/canon" check </dev/null 2>&1)" || status=$?
  echo "$findings"
  [ "$status" -ne 0 ]
  echo "$findings" | grep -q "^./adder.py:1:1: missing canonical comment on python/adder.py/function/add$"
fi
cd /
rm -rf "$scratch"
echo "== smoke test passed"
'

absolute()
{
  echo "$(cd "$(dirname "$1")" && pwd)/$(basename "$1")"
}

case "$platform" in
  linux-arm64 | linux-x64)
    case "$platform" in
      linux-arm64) arch=arm64 ;;
      linux-x64) arch=amd64 ;;
    esac
    container="lawspec-native-smoke-$platform-$$"
    trap 'podman rm -f "$container" >/dev/null 2>&1 || true' EXIT
    podman create --name "$container" --platform "linux/$arch" "$debian" \
      sh -c "$checks" smoke /usr/local/bin/lawspec ${canon:+/opt/canon} >/dev/null
    podman cp "$binary" "$container:/usr/local/bin/lawspec"
    if [ -n "$canon" ]; then
      podman cp "$canon" "$container:/opt/canon"
    fi
    podman start -a "$container"
    ;;
  darwin-x64)
    arch -x86_64 /bin/sh -c "$checks" smoke "$(absolute "$binary")" ${canon:+"$(cd "$canon" && pwd)"}
    ;;
  darwin-arm64)
    /bin/sh -c "$checks" smoke "$(absolute "$binary")" ${canon:+"$(cd "$canon" && pwd)"}
    ;;
  *)
    echo "smoke-native: unknown platform $platform" >&2
    exit 2
    ;;
esac
