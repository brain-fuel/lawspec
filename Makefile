.PHONY: test wasm check package integration

test:
	stack --no-terminal test
	node --test npm/test/*.test.mjs

wasm:
	tools/wasm.sh

check: test
	node tools/build-integrity.mjs
	node tools/parity.mjs

package:
	node tools/package-smoke.mjs

integration:
	node tools/bootstrap-integration.mjs
	node tools/integration.mjs

.PHONY: examples
examples:
	node npm/bin/lawspec.mjs examples
