#!/bin/sh
# Independent artifact validators use a local, pinned Python environment and
# ANTLR tool. OpenTofu and a JDK come from the caller's toolchain.
# ref:REQ-artifact-targets ref:DEC-artifact-targets
set -eu
cd "$(dirname "$0")/.."
artifact_environment=.tools/config-targets
artifact_bootstrap_python=${LAWSPEC_ARTIFACT_BOOTSTRAP_PYTHON:-python3}
if [ ! -x "$artifact_environment/bin/python" ]; then
  "$artifact_bootstrap_python" -m venv "$artifact_environment"
fi
if ! "$artifact_environment/bin/python" -c 'import importlib.metadata as m; assert m.version("jsonschema")=="4.25.1" and m.version("PyYAML")=="6.0.3"' 2>/dev/null; then
  "$artifact_environment/bin/pip" install --disable-pip-version-check 'jsonschema==4.25.1' 'PyYAML==6.0.3'
fi
ANTLR_JAR=${ANTLR_JAR:-"$PWD/.tools/antlr-4.13.2-complete.jar"}
if [ ! -f "$ANTLR_JAR" ]; then
  mkdir -p "$(dirname "$ANTLR_JAR")"
  artifact_download="$ANTLR_JAR.download.$$"
  trap 'rm -f "$artifact_download"' EXIT HUP INT TERM
  curl --fail --location --silent --show-error https://www.antlr.org/download/antlr-4.13.2-complete.jar --output "$artifact_download"
  "$artifact_environment/bin/python" - "$artifact_download" <<'PY'
import hashlib,sys
from pathlib import Path
assert hashlib.sha256(Path(sys.argv[1]).read_bytes()).hexdigest() == 'eae2dfa119a64327444672aff63e9ec35a20180dc5b8090b7a6ab85125df4d76', 'ANTLR checksum mismatch'
PY
  mv "$artifact_download" "$ANTLR_JAR"
  trap - EXIT HUP INT TERM
fi
"$artifact_environment/bin/python" - "$ANTLR_JAR" <<'PY'
import hashlib,sys
from pathlib import Path
assert hashlib.sha256(Path(sys.argv[1]).read_bytes()).hexdigest() == 'eae2dfa119a64327444672aff63e9ec35a20180dc5b8090b7a6ab85125df4d76', 'ANTLR 4.13.2 is required'
PY
export ANTLR_JAR
if [ "${1:-}" = --setup ]; then exit 0; fi
if [ -z "${LAWSPEC_NATIVE_CORE:-}" ]; then
  LAWSPEC_NATIVE_CORE="$(stack path --local-install-root)/bin/lawspec-core"
fi
export LAWSPEC_NATIVE_CORE
exec "$artifact_environment/bin/python" tools/artifact-targets.py "$@"
