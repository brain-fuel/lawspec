#!/usr/bin/env bash
# Packs the host-effect core (npm/host-core.wasm, from tools/wasm.sh) as the
# npm package @goforgedev/core, which the Go host downloads on first use and
# checks against the SHA-256 hosts/go/internal/core/pin.go records. It only
# packs; the owner publishes the archive exactly as packed.
# Usage: tools/package-core.sh [--out <directory>]
#   --out  where the archive goes; .artifacts/core-npm by default
# The package's version is LawSpec's (package.yaml), the version pin.go
# names. The core must be the one npm/build.json and pin.go record.
# ref:DEC-go-core-download
set -euo pipefail
cd "$(dirname "$0")/.."
root="$PWD"

out="$root/.artifacts/core-npm"
while [ $# -gt 0 ]; do
  case "$1" in
    --out) out="${2:?--out needs a directory}"; shift 2 ;;
    *)
      echo "usage: tools/package-core.sh [--out <directory>]" >&2
      exit 2
      ;;
  esac
done
core=npm/host-core.wasm
[ -f "$core" ] || { echo "package-core: no $core; run tools/wasm.sh" >&2; exit 1; }
version="$(sed -n 's/^version: //p' package.yaml)"
digest="$(shasum -a 256 "$core" | cut -d' ' -f1)"
pin=hosts/go/internal/core/pin.go
grep -q "^const Version = \"$version\"$" "$pin" && grep -q "^const SHA256 = \"$digest\"$" "$pin" ||
  { echo "package-core: $pin does not record $core ($digest) for $version; run tools/wasm.sh" >&2; exit 1; }

staging="$(mktemp -d)"
trap 'rm -rf "$staging"' EXIT
cp "$core" "$staging/host-core.wasm"
cp LICENSE "$staging/LICENSE"
cat >"$staging/package.json" <<JSON
{
  "name": "@goforgedev/core",
  "version": "$version",
  "description": "The LawSpec $version host-effect core, a WebAssembly module, which the LawSpec Go host downloads and verifies.",
  "license": "MIT",
  "files": ["host-core.wasm", "LICENSE"]
}
JSON
cat >"$staging/README.md" <<MARKDOWN
# @goforgedev/core

The LawSpec $version host-effect core (\`host-core.wasm\`, SHA-256
\`$digest\`), the WebAssembly module every LawSpec host runs. The Go host
(\`goforge.dev/lawspec\`) downloads it on first use and runs it only if its
SHA-256 is the one the module records. Install \`lawspec\` or the Go module,
not this package.
MARKDOWN
mkdir -p "$out"
(cd "$staging" && npm pack --silent --pack-destination "$out" >/dev/null)
echo "$out/goforgedev-core-$version.tgz"
