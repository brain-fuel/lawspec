#!/usr/bin/env bash
# Packs a Canon bundle (tools/build-canon.sh) as the optional npm package
# @goforgedev/canon-<platform>, which the Node host finds beside the lawspec
# package and runs for lawspec project (see templates/npm/bin/lawspec.mjs).
# It only packs; the owner publishes the archive exactly as packed. Its
# integrity is recorded in component/canon-packages.json, from which
# tools/npm-lock.mjs pins it in npm/package-lock.json before it is published.
# Usage: tools/package-canon.sh [--platform <platform>] [--bundle <directory>] [--out <directory>]
#   --platform  darwin-arm64, darwin-x64, linux-arm64 or linux-x64; this
#               machine's by default
#   --bundle    the bundle; .artifacts/canon/<platform> by default
#   --out       where the archive goes; .artifacts/canon-npm by default
# The package's version is LawSpec's (package.yaml), so the lawspec package
# can pin it exactly in optionalDependencies, as it pins
# @goforgedev/compiler-<platform>; os and cpu let npm skip it elsewhere.
# ref:DEC-native-canon
set -euo pipefail
cd "$(dirname "$0")/.."
root="$PWD"

case "$(uname -s)-$(uname -m)" in
  Darwin-arm64) platform=darwin-arm64 ;;
  Darwin-x86_64) platform=darwin-x64 ;;
  Linux-aarch64) platform=linux-arm64 ;;
  Linux-x86_64) platform=linux-x64 ;;
  *) platform="" ;;
esac
bundle=""
out="$root/.artifacts/canon-npm"
while [ $# -gt 0 ]; do
  case "$1" in
    --platform) platform="${2:?--platform needs a platform}"; shift 2 ;;
    --bundle) bundle="${2:?--bundle needs a directory}"; shift 2 ;;
    --out) out="${2:?--out needs a directory}"; shift 2 ;;
    *)
      echo "usage: tools/package-canon.sh [--platform <platform>] [--bundle <directory>] [--out <directory>]" >&2
      exit 2
      ;;
  esac
done
case "$platform" in
  darwin-arm64) os=darwin; cpu=arm64 ;;
  darwin-x64) os=darwin; cpu=x64 ;;
  linux-arm64) os=linux; cpu=arm64 ;;
  linux-x64) os=linux; cpu=x64 ;;
  *) echo "package-canon: unknown platform '$platform'" >&2; exit 2 ;;
esac
bundle="${bundle:-$root/.artifacts/canon/$platform}"
[ -f "$bundle/canon.json" ] && [ -f "$bundle/canon" ] && [ -d "$bundle/presets" ] ||
  { echo "package-canon: $bundle is not a Canon bundle; run tools/build-canon.sh on $platform" >&2; exit 1; }
grep -q "\"platform\": \"$platform\"" "$bundle/canon.json" ||
  { echo "package-canon: $bundle is not built for $platform" >&2; exit 1; }
[ "$(shasum -a 256 "$bundle/canon" | cut -d' ' -f1)" = "$(cat "$bundle/canon.sha256")" ] ||
  { echo "package-canon: $bundle/canon does not match its canon.sha256" >&2; exit 1; }
version="$(sed -n 's/^version: //p' package.yaml)"
canon_version="$(sed -n 's/^ *"canon": "\(.*\)",$/\1/p' "$bundle/canon.json")"

staging="$(mktemp -d)"
trap 'rm -rf "$staging"' EXIT
cp "$bundle/canon" "$bundle/canon.json" "$staging/"
cp -R "$bundle/presets" "$staging/presets"
cp "$bundle/presets/CANON-LICENSE" "$staging/LICENSE"
chmod 755 "$staging/canon"
cat >"$staging/package.json" <<JSON
{
  "name": "@goforgedev/canon-$platform",
  "version": "$version",
  "description": "Canon $canon_version for LawSpec's lawspec project on $platform: the native canon executable and Rice's Tax 0.4.3's grammar presets.",
  "license": "MIT",
  "os": ["$os"],
  "cpu": ["$cpu"],
  "files": ["canon", "canon.json", "presets", "LICENSE"]
}
JSON
cat >"$staging/README.md" <<MARKDOWN
# @goforgedev/canon-$platform

Canon $canon_version, built natively for $platform, with the grammar presets
of Rice's Tax 0.4.3. The LawSpec Node host runs it for \`lawspec project\`;
\`canon.json\` names the commits it was built from. Install \`lawspec\`, not
this package.
MARKDOWN
mkdir -p "$out"
(cd "$staging" && npm pack --silent --pack-destination "$out" >/dev/null)
archive="$out/goforgedev-canon-$platform-$version.tgz"
node --input-type=module - "$root/component/canon-packages.json" "$platform" "$archive" "$version" <<'JS'
import {createHash} from 'node:crypto';
import {readFileSync, writeFileSync, existsSync} from 'node:fs';
import path from 'node:path';
const [record, platform, archive, version] = process.argv.slice(2);
const bytes = readFileSync(archive);
const packages = existsSync(record) ? JSON.parse(readFileSync(record, 'utf8')) : {};
packages[platform] = {
  name: `@goforgedev/canon-${platform}`,
  version,
  file: path.basename(archive),
  integrity: `sha512-${createHash('sha512').update(bytes).digest('base64')}`,
  shasum: createHash('sha1').update(bytes).digest('hex'),
};
const order = ['darwin-arm64', 'darwin-x64', 'linux-arm64', 'linux-x64'];
const sorted = Object.fromEntries(order.filter(name => packages[name]).map(name => [name, packages[name]]));
writeFileSync(record, JSON.stringify(sorted, null, 2) + '\n');
JS
echo "$archive"
