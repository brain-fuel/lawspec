#!/usr/bin/env bash
# Compares a cross-built lawspec-native with this Mac's own build, byte for
# byte, over the bundled example specs:
#   tools/native/parity-native.sh --platform <platform> --binary <path> \
#     --reference <darwin-arm64 lawspec-native> [--only <glob>]
# Each examples/specs/*.lawspec (or those matching --only) gets a project of
# its own (init --target yaml, the spec as its only source), where fmt
# --check, check and generate run in turn. Their standard output, standard
# error, exit code and the project's resulting files must match the
# reference's, apart from .lawspec/cache, whose entries are keyed by the
# build machine. A Linux binary runs in a clean Debian container of its
# architecture (removed afterwards) at the same absolute path the reference
# used, so paths in messages compare equal; darwin-x64 runs under
# arch -x86_64. This is a subset of tools/hosts.sh parity, which also needs
# the WebAssembly core and the legacy CLI; it checks that a platform's build
# renders what the reference renders. See docs/how-to/build-native.md.
set -euo pipefail
repository="$(cd "$(dirname "$0")/../.." && pwd)"
debian=docker.io/library/debian:bookworm-slim@sha256:734a72b3d6142a71993b4bc580ca01d8ca687f77a2c422d96a961d3376b179bc

platform=""
binary=""
reference=""
only="*"
while [ $# -gt 0 ]; do
  case "$1" in
    --platform) platform="${2:?--platform needs a platform}"; shift 2 ;;
    --binary) binary="${2:?--binary needs a path}"; shift 2 ;;
    --reference) reference="${2:?--reference needs a path}"; shift 2 ;;
    --only) only="${2:?--only needs a glob}"; shift 2 ;;
    *) echo "usage: parity-native.sh --platform <platform> --binary <path> --reference <path> [--only <glob>]" >&2; exit 2 ;;
  esac
done
[ -n "$platform" ] && [ -f "$binary" ] && [ -f "$reference" ] || { echo "usage: parity-native.sh --platform <platform> --binary <path> --reference <path> [--only <glob>]" >&2; exit 2; }
binary="$(cd "$(dirname "$binary")" && pwd)/$(basename "$binary")"
reference="$(cd "$(dirname "$reference")" && pwd)/$(basename "$reference")"

# One run of the corpus, as a POSIX shell script: $1 the binary, $2 the
# directory of specs, $3 the glob, $4 the work root, $5 the results
# directory. Every command's output and the project's files (by cksum) are
# recorded per spec.
run='
set -u
lawspec="$1"; specs="$2"; only="$3"; root="$4"; results="$5"
mkdir -p "$root" "$results"
for spec in "$specs"/*.lawspec; do
  name="$(basename "$spec" .lawspec)"
  case "$name" in $only) ;; *) continue ;; esac
  project="$root/$name"
  mkdir -p "$project"
  cd "$project"
  "$lawspec" init --target yaml </dev/null >/dev/null 2>&1
  rm -f laws/*.lawspec
  cp "$spec" laws/
  for command in "fmt --check" check generate; do
    tag="$name.$(echo "$command" | tr " " "_")"
    $lawspec $command </dev/null >"$results/$tag.out" 2>"$results/$tag.err"
    echo "$?" >"$results/$tag.exit"
  done
  find . -type f ! -path "./.lawspec/cache/*" | LC_ALL=C sort | while read -r file; do cksum <"$file" | sed "s|\$| $file|"; done >"$results/$name.files"
  cd "$root"
  rm -rf "$project"
done
'

scratch="$(mktemp -d)"
scratch="$(cd "$scratch" && pwd -P)"
trap 'rm -rf "$scratch"' EXIT
mkdir "$scratch/specs"
cp "$repository"/examples/specs/*.lawspec "$scratch/specs/"
printf '%s' "$run" >"$scratch/run.sh"

echo "parity-native: reference (darwin-arm64)"
/bin/sh "$scratch/run.sh" "$reference" "$scratch/specs" "$only" "$scratch/work" "$scratch/reference"

echo "parity-native: $platform"
case "$platform" in
  linux-arm64 | linux-x64)
    case "$platform" in
      linux-arm64) arch=arm64 ;;
      linux-x64) arch=amd64 ;;
    esac
    container="lawspec-native-parity-$platform-$$"
    trap 'podman rm -f "$container" >/dev/null 2>&1 || true; rm -rf "$scratch"' EXIT
    # The specs and the script go in, and the results come out, as tar
    # archives on the container's standard streams.
    podman create -i --name "$container" --platform "linux/$arch" "$debian" \
      sh -c 'mkdir -p "$1" && tar -x -C "$1" && sh "$1/run.sh" /usr/local/bin/lawspec "$1/specs" "$2" "$1/work" "$1/candidate" >&2 && tar -c -C "$1" candidate' \
      parity "$scratch" "$only" >/dev/null
    podman cp "$binary" "$container:/usr/local/bin/lawspec"
    COPYFILE_DISABLE=1 tar -c -C "$scratch" specs run.sh | podman start -ai "$container" | tar -x -C "$scratch"
    ;;
  darwin-x64)
    arch -x86_64 /bin/sh "$scratch/run.sh" "$binary" "$scratch/specs" "$only" "$scratch/work" "$scratch/candidate"
    ;;
  *)
    /bin/sh "$scratch/run.sh" "$binary" "$scratch/specs" "$only" "$scratch/work" "$scratch/candidate"
    ;;
esac

cases="$(find "$scratch/reference" -name '*.files' | wc -l | tr -d ' ')"
if diff -r "$scratch/reference" "$scratch/candidate"; then
  echo "parity-native: $platform matches the reference on $cases spec(s), 3 commands each."
else
  echo "parity-native: $platform differs from the reference (above)." >&2
  exit 1
fi
