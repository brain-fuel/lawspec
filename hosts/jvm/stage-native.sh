#!/usr/bin/env bash
# Stages a natively compiled lawspec (stack's lawspec-native) for the JVM
# platform jars, and writes the launcher's manifest of every staged binary.
#   hosts/jvm/stage-native.sh
#       stages this machine's own build: stack's lawspec-native, stripped,
#       and the Canon bundle tools/build-canon.sh builds (it builds it first
#       unless it is already built)
#   hosts/jvm/stage-native.sh --platform <platform> --binary <path> [--canon <bundle>]
#       stages a binary built on that platform (already stripped there), and
#       the Canon bundle tools/build-canon.sh built there
#   hosts/jvm/stage-native.sh --check-all
#       fails unless all four platforms are staged (a release needs them)
# Platforms: darwin-arm64, darwin-x64, linux-arm64, linux-x64. A binary is
# never cross-built here: GHC builds lawspec-native for the platform it runs
# on, so each platform's binary comes from a build on that platform, real or
# emulated: tools/build-native.sh builds all four on an Apple Silicon Mac
# (docs/how-to/build-native.md). The binary's
# format and architecture are checked with file(1) before it is staged.
# Staging: .artifacts/jvm/natives/<platform>/lawspec and lawspec.sha256, the
# Canon bundle in canon/ (the canon executable, canon.sha256 and presets/),
# and natives.properties, which the launcher jar carries as its manifest.
# ref:DEC-jvm-native-host ref:DEC-native-canon
set -euo pipefail
cd "$(dirname "$0")/../.."
natives=.artifacts/jvm/natives
platforms=(darwin-arm64 darwin-x64 linux-arm64 linux-x64)

host_platform()
{
  local os arch
  case "$(uname -s)" in
    Darwin) os=darwin ;;
    Linux) os=linux ;;
    *) echo "stage-native: unsupported build system $(uname -s)" >&2; exit 2 ;;
  esac
  case "$(uname -m)" in
    arm64 | aarch64) arch=arm64 ;;
    x86_64 | amd64) arch=x64 ;;
    *) echo "stage-native: unsupported architecture $(uname -m)" >&2; exit 2 ;;
  esac
  echo "$os-$arch"
}

# What file(1) says of each platform's executables.
expected_format()
{
  case "$1" in
    darwin-arm64) echo 'Mach-O 64-bit executable arm64' ;;
    darwin-x64) echo 'Mach-O 64-bit executable x86_64' ;;
    linux-arm64) echo 'ELF 64-bit LSB .*ARM aarch64' ;;
    linux-x64) echo 'ELF 64-bit LSB .*x86-64' ;;
    *) echo "stage-native: unknown platform $1 (one of ${platforms[*]})" >&2; exit 2 ;;
  esac
}

write_manifest()
{
  local manifest="$natives/natives.properties" p
  mkdir -p "$natives"
  {
    echo "# The SHA-256 and size of each staged lawspec; written by hosts/jvm/stage-native.sh."
    for p in "${platforms[@]}"; do
      if [ -f "$natives/$p/lawspec.sha256" ]; then
        echo "$p.sha256=$(cat "$natives/$p/lawspec.sha256")"
        echo "$p.size=$(wc -c <"$natives/$p/lawspec" | tr -d ' ')"
      fi
      if [ -f "$natives/$p/canon/canon.sha256" ]; then
        echo "$p.canon.sha256=$(cat "$natives/$p/canon/canon.sha256")"
        echo "$p.canon.size=$(wc -c <"$natives/$p/canon/canon" | tr -d ' ')"
      fi
    done
  } >"$manifest.tmp"
  mv -f "$manifest.tmp" "$manifest"
}

platform=""
binary=""
canon=""
own=false
case "${1:-}" in
  --check-all)
    missing=()
    for p in "${platforms[@]}"; do
      [ -f "$natives/$p/lawspec" ] && [ -f "$natives/$p/lawspec.sha256" ] && [ -f "$natives/$p/canon/canon.sha256" ] || missing+=("$p")
    done
    if [ ${#missing[@]} -gt 0 ]; then
      echo "stage-native: not staged: ${missing[*]}. Build lawspec-native and Canon on each with tools/build-native.sh --platform <platform> [--canon] and stage them with --platform <platform> --binary <path> --canon <bundle>." >&2
      exit 1
    fi
    echo "All four platforms are staged."
    exit 0
    ;;
  --platform)
    platform="${2:?--platform needs a platform}"
    [ "${3:-}" = "--binary" ] || { echo "usage: stage-native.sh --platform <platform> --binary <path>" >&2; exit 2; }
    binary="${4:?--binary needs a path}"
    if [ "${5:-}" = "--canon" ]; then
      canon="${6:?--canon needs a directory}"
    fi
    ;;
  "")
    platform="$(host_platform)"
    binary="$(stack --no-terminal path --local-install-root)/bin/lawspec-native"
    canon="$(tools/build-canon.sh --print)"
    own=true
    ;;
  *)
    echo "usage: stage-native.sh [--platform <platform> --binary <path> [--canon <bundle>] | --check-all]" >&2
    exit 2
    ;;
esac

[ -f "$binary" ] || { echo "stage-native: no binary at $binary (build it with stack build lawspec:exe:lawspec-native)" >&2; exit 1; }
format="$(expected_format "$platform")"
if ! file -b "$binary" | grep -Eq "$format"; then
  echo "stage-native: $binary is not a $platform executable: $(file -b "$binary")" >&2
  exit 1
fi
mkdir -p "$natives/$platform"
staged="$natives/$platform/lawspec"
cp -f "$binary" "$staged.tmp"
chmod 755 "$staged.tmp"
# Strip this machine's own build; a binary from another platform arrives
# stripped by that platform's strip(1).
if $own; then
  strip "$staged.tmp"
fi
mv -f "$staged.tmp" "$staged"
shasum -a 256 "$staged" | cut -d' ' -f1 >"$natives/$platform/lawspec.sha256"
if [ -n "$canon" ]; then
  [ -f "$canon/canon" ] && [ -d "$canon/presets" ] || { echo "stage-native: $canon is not a Canon bundle (tools/build-canon.sh)" >&2; exit 1; }
  if ! file -b "$canon/canon" | grep -Eq "$format"; then
    echo "stage-native: $canon/canon is not a $platform executable: $(file -b "$canon/canon")" >&2
    exit 1
  fi
  [ "$(shasum -a 256 "$canon/canon" | cut -d' ' -f1)" = "$(cat "$canon/canon.sha256")" ] || { echo "stage-native: $canon/canon does not match its canon.sha256" >&2; exit 1; }
  rm -rf "$natives/$platform/canon.tmp"
  mkdir -p "$natives/$platform/canon.tmp"
  cp -R "$canon/canon" "$canon/canon.sha256" "$canon/canon.json" "$canon/presets" "$natives/$platform/canon.tmp/"
  rm -rf "$natives/$platform/canon"
  mv "$natives/$platform/canon.tmp" "$natives/$platform/canon"
fi
write_manifest
echo "$platform: $(cat "$natives/$platform/lawspec.sha256") $staged"
if [ -n "$canon" ]; then
  echo "$platform: canon $(cat "$natives/$platform/canon/canon.sha256") $natives/$platform/canon"
fi
