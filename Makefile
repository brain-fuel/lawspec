# LawSpec development tasks. `make` lists them. Every check runs locally;
# there is no hosted CI. See docs/how-to/contribute.md and docs/how-to/release.md.

STACK   := stack --no-terminal
DEV     := $(STACK) run lawspec-dev --
VERSION := $(shell sed -n 's/^version: //p' package.yaml)
SUITE   ?= integration
TARGET  ?=
SITE    := .artifacts/site

.DEFAULT_GOAL := help
.PHONY: help build generate generate-check wasm test integrity boundaries check parity \
        smoke package acceptance lessons ci ci-fresh ci-core examples editor-test docs docs-check \
        docs-serve docs-deploy canon bump version release-check clean

help: ## List the tasks
	@awk -F':.*## ' '/^[a-z-]+:.*## / {printf "  %-15s %s\n", $$1, $$2}' $(MAKEFILE_LIST)

build: ## Build the compiler, tools and tests
	$(STACK) build --test --no-run-tests

generate: ## Regenerate JavaScript and embedded runtimes from templates/
	$(DEV) generate

generate-check: ## Fail if a generated file is stale
	$(DEV) generate --check

wasm: ## Build core.wasm and stage the npm package (needs wasm32-wasi-ghc)
	tools/wasm.sh

test: ## Compiler tests and npm tests
	$(STACK) test
	node --test npm/test/*.test.mjs

integrity: ## npm/build.json matches the sources and the WASM build
	$(DEV) integrity

boundaries: ## Core and emitters never import syntax or inference
	$(DEV) boundaries

check: generate-check integrity boundaries test parity ## Fast local checks

parity: ## Native and WASM compilers agree
	node tools/parity.mjs

smoke: ## Pack, install and exercise the npm package
	node tools/package-smoke.mjs

package: ## Pack the npm package into .artifacts/<version>/
	mkdir -p .artifacts/$(VERSION)
	npm pack ./npm --pack-destination .artifacts/$(VERSION)

acceptance: ## One acceptance suite: make acceptance SUITE=domain TARGET=java
	$(STACK) build lawspec:exe:lawspec-acceptance
	$(STACK) exec lawspec-acceptance -- $(SUITE) $(TARGET)

lessons: ## The tutorial lessons, run for real in Java, Python, JavaScript and TypeScript
	$(STACK) build lawspec:exe:lawspec-acceptance
	$(STACK) exec lawspec-acceptance -- lessons java python javascript typescript

ci: ## The complete check: every step for all eight targets
	$(DEV) ci

ci-fresh: ## The complete check, ignoring recorded results (for releases)
	$(DEV) ci --fresh

ci-core: ## The complete check without target toolchains
	$(DEV) ci --core

examples: ## Generate every bundled example into example_artifacts/
	node npm/bin/lawspec.mjs examples

editor-test: ## VS Code grammar tests
	npm test --prefix editors/vscode

docs: ## Build the documentation site into .artifacts/site
	$(DEV) docs --out $(SITE)

docs-check: ## Compile every documentation snippet and check links
	$(DEV) docs --check

canon: ## Check the canonical format with canon (needs CANON_HOME)
	$(DEV) canon check

docs-serve: docs ## Serve the documentation site on http://localhost:8000
	python3 -m http.server --directory $(SITE) 8000

docs-deploy: docs ## Deploy the site to Cloudflare Pages (needs wrangler login)
	npx wrangler pages deploy $(SITE) --project-name lawspec-docs --branch main

bump: ## Set the release version: make bump VERSION=x.y.z
	$(DEV) bump $(VERSION)

version: ## Print the release version and check every file agrees
	$(DEV) version --check

release-check: ## Preconditions for a release (see docs/how-to/release.md)
	@test "$$(git branch --show-current)" = main || (echo "Release from main" && exit 1)
	@test -z "$$(git status --porcelain)" || (echo "The working tree is not clean" && exit 1)
	$(DEV) version --check
	$(DEV) generate --check
	@! git rev-parse -q --verify "refs/tags/v$(VERSION)" >/dev/null || (echo "Tag v$(VERSION) exists" && exit 1)
	@! npm view "lawspec@$(VERSION)" version --registry https://registry.npmjs.org 2>/dev/null | grep -q . || (echo "lawspec@$(VERSION) is already published" && exit 1)
	@echo "Ready to release $(VERSION)."

clean: ## Remove CI logs and the built site
	rm -rf .artifacts/ci $(SITE)
