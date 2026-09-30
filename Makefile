.PHONY: test wasm check package integration ci

test:
	stack --no-terminal test
	node --test npm/test/*.test.mjs

wasm:
	tools/wasm.sh

check: test
	stack --no-terminal run lawspec-dev -- integrity
	stack --no-terminal run lawspec-dev -- boundaries
	node tools/parity.mjs

package:
	node tools/package-smoke.mjs

# The complete check: compiler, npm, editor and all eight targets.
ci:
	stack --no-terminal run lawspec-dev -- ci

integration:
	stack --no-terminal run lawspec-dev -- ci --fail-fast

.PHONY: examples
examples:
	node npm/bin/lawspec.mjs examples
