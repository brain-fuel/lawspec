# Contributing to LawSpec

This guide is for working on LawSpec itself. To use LawSpec, see the
[documentation](docs/index.md).

## Repository layout

| Directory | Contents |
| --- | --- |
| `src/` | The compiler library: parser, imports, inference, elaboration, Core, prover, testing planner and the eight emitters. |
| `app/` | `lawspec-core`, the native compiler executable. It reads a JSON request on standard input and writes the result. |
| `dev/` | `lawspec-dev`: repository checks (`boundaries`, `integrity`), code generation, and the local CI driver. |
| `acceptance/` | `lawspec-acceptance` and its suites, which run the bundled examples on every target. |
| `test/` | The Hspec test suite, `lawspec-test`, and its fixtures. |
| `npm/` | The npm package payload: the Node CLI, API wrapper, WASM core and bundled examples. |
| `runtime/` | Target runtime sources, embedded into the compiler and emitted into generated projects. |
| `examples/` | Example specifications, the native-binding payment projects, and the package example. |
| `editors/vscode/` | The syntax-highlighting grammar and VS Code extension. |
| `wasm/` | The Cabal project that builds the compiler for WebAssembly. |
| `templates/` | The sources of every JavaScript file in the repository, and of the documentation site. |
| `tools/` | Build and integration scripts, generated from `templates/tools/`. |
| `docs/` | The documentation site. |

## Building

Stack is the native development tool:

```sh
stack --no-terminal build
stack --no-terminal test
```

To try a request against the native compiler:

```sh
printf '%s' '{"method":"check","sources":[{"path":"x.lawspec","content":"unit example.empty"}]}' | stack exec lawspec-core
```

### WebAssembly

The npm package ships the compiler as WebAssembly, built with GHC's wasm32-wasi
backend and Cabal. Install `wasm32-wasi-ghc` and `wasm32-wasi-cabal` through
[ghc-wasm-meta](https://gitlab.haskell.org/haskell-wasm/ghc-wasm-meta), then:

```sh
tools/wasm.sh
```

The script reads `~/.ghc-wasm/env` when present. It builds the WASM core and
its JavaScript glue, stages the package files in `npm/`, and records compiler
source and artifact hashes in `npm/build.json`. WASM dependencies are frozen in
`wasm/cabal.project.freeze`. The npm archive is self-contained: no install-time
compilation or download.

To build and install a local archive:

```sh
npm pack ./npm
npm install --save-dev ./lawspec-0.17.5.tgz
```

## Generated files

Every JavaScript file in the repository is generated, deterministically, by
`lawspec-dev generate` (`make generate`) from a template in `templates/` and
facts the Haskell code owns. `templates/<path>` produces `<path>`: for example
`templates/npm/bin/lawspec.mjs` produces `npm/bin/lawspec.mjs`. Edit the
template, never the output; each output starts with a comment naming its
template.

A template is ordinary JavaScript with named holes that Haskell fills:

| Hole | Filled with |
| --- | --- |
| `/*@ name @*/` | a value, such as `/*@ version @*/` or `/*@ targets @*/` |
| `//@ name` alone on a line | lines of code, such as a shared partial |
| `<!--@ name @-->` | a value, in the site's HTML templates |

The facts come from `package.yaml` (the version) and `LawSpec.Scaffold` (targets,
project scaffolds, test commands and setup advice); `dev/Generate.hs` lists
them. `templates/partials/` holds code shared between templates, included as
`//@ partial-<name>`: the WebAssembly instantiation shared by the Node and
browser launchers, for example. `npm/api.mjs` and `npm/index.d.ts` are rendered
from `dev/Gen/Api.hs`, and `src/LawSpec/RuntimeSources.hs` embeds `runtime/`.

`lawspec-dev generate --check` (`make generate-check`, and a CI step) fails if
an output is stale or if any script in the repository is neither generated nor
one of the exempt kinds: user-owned code (acceptance adapters, examples,
fixtures), the embedded runtimes in `runtime/`, and GHC's post-linker output
`npm/core_jsffi.js`.

`lawspec-dev integrity` rejects a stale WASM build and staged npm copies that
differ from their sources.

## Checks

The complete check runs locally. There is no hosted CI. Install the eight
targets' build tools, then:

```sh
stack run lawspec-dev -- ci                          # everything
stack run lawspec-dev -- ci --target rust --target go
stack run lawspec-dev -- ci --core                   # compiler, npm and editor only
stack run lawspec-dev -- ci --fail-fast
stack run lawspec-dev -- ci --fresh                  # ignore recorded results
stack run lawspec-dev -- ci --rust-toolchains 1.85.0,stable --rust-targets i686-unknown-linux-gnu
```

`make ci` is equivalent to the first form. The check runs the compiler, npm,
native/WASM parity, package and editor checks. Then, for each target, it
bootstraps the pinned test dependencies, runs every acceptance suite in both
machine profiles, and runs the installed native-binding example. Each step logs
to `.artifacts/ci/<step>.log`. Every step runs even after a failure unless
`--fail-fast` is given, and the command exits non-zero if any step failed.

Results are content-addressed, so a second run only repeats what changed:

- Each acceptance run is keyed by the project it generates, the suite's
  adapters, stubs and mutants, the harness, and the toolchain's versions,
  dependency locks and environment. A compiler change that leaves a target's
  generated files unchanged reuses that target's results; the console marks
  them `(cached)`.
- The compiler, npm, parity, package, docs and Rust runtime steps are keyed by
  the bytes of the repository files they read (tracked or untracked, not
  ignored) and their tools' versions, and print `cached`.

Passes are recorded in `.artifacts/cache`; delete it to forget them.
`--fresh` (or `make ci-fresh`) runs everything, as a release does.
Fresh runs still record their passes. For a single `lawspec-acceptance` run,
`LAWSPEC_CACHE=refresh` reruns and records, and `LAWSPEC_CACHE=0` turns the
cache off.

Smaller checks:

```sh
stack --no-terminal test                        # compiler tests
node --test npm/test/*.test.mjs                 # npm package tests
stack run lawspec-dev -- boundaries             # Core and emitters never import syntax or inference
stack run lawspec-dev -- integrity              # build fingerprints and staged copies
node tools/parity.mjs                           # native and WASM output agree
node tools/package-smoke.mjs                    # pack, install and use the archive
```

`make test`, `make check` and `make package` group these.

## Acceptance suites

`lawspec-acceptance` generates a suite's bundled examples in process, installs
the suite's adapters, runs the target's own test command, and requires every
mutant to fail its laws at test time. A mutant that only breaks the build fails
the suite.

```sh
node tools/bootstrap-integration.mjs                 # install pinned test dependencies
stack run lawspec-acceptance -- integration          # all eight targets
stack run lawspec-acceptance -- scalar rust          # one suite, one target
stack run lawspec-acceptance -- domain --check       # regenerate and compare only
stack run lawspec-acceptance -- algebra --no-mutants # correct adapters only
LAWSPEC_MACHINE_BITS=32 LAWSPEC_MINIFY=1 stack run lawspec-acceptance -- indexed go
```

The suites are `integration`, `algebra`, `scalar`, `refinement`, `indexed`,
`domain` and `packages`. Output goes to `.artifacts/<suite>[32][-compact]/<target>`.
Bootstrap installs dependencies into isolated `.integration/` projects.

A suite lives in `acceptance/<suite>/`:

| Path | Contents |
| --- | --- |
| `suite.json` | `{"specs": [...]}`, plus optional `"vectors"` (scalar conformance vectors), `"architecture": true`, `"packages"` and `"dependencies"` |
| `<target>/files/<path>` | Real adapter sources, replacing the generated stubs |
| `<target>/stubs/<path>` | The stub each adapter was written against (optional) |
| `<target>/mutants/<name>.mutant` | One search-and-replace edit per mutant |

With stubs, a regenerated stub that differs fails the suite, so an adapter
signature change is always reviewed, and the bare stub is itself a mutant that
must fail. With `architecture`, a profile whose width differs from the host must
be rejected by native machine-sized adapters (Go, Haskell, Rust).

Environment:

- `LAWSPEC_MACHINE_BITS=32` and `LAWSPEC_MINIFY=1` select the profile and
  output format.
- `LAWSPEC_OFFLINE=1` uses existing dependency caches.
- `LAWSPEC_PYTHON=3.14` selects the additional Python reference environment.
- Gradle 9.3.0 is used from `.tools/gradle-9.3.0` when present, otherwise from
  `PATH`.

### Native-binding example

`node tools/native-example-integration.mjs <target>` tests the public path end
to end: it packs and installs the archive, exports the payment project, prepares
native dependencies, runs `lawspec check` and `generate`, runs the native test
command, rejects an incorrect fee implementation, re-exports, and checks that
regeneration is a no-op. Logs are kept in `.artifacts/native-example-integration/`.

```sh
node tools/native-example-integration.mjs rust
LAWSPEC_MACHINE_BITS=32 LAWSPEC_MINIFY=1 node tools/native-example-integration.mjs rust
```

`LAWSPEC_PYTHON` selects the Python version for uv, and
`LAWSPEC_PYTHON_EXECUTABLE` an existing interpreter. `LAWSPEC_NODE_MODULES` and
`LAWSPEC_GRADLE` select existing web dependencies and Gradle. `STACK_ROOT` and
`GRADLE_USER_HOME` can point at writable copies of existing caches.

## Formatting of generated code

Formatting is implemented in the compiler, with `LawSpec.Code.Doc`; generation
never runs an external formatter. Each target's output follows that language's
usual style (Google style for Java, Kotlin, JavaScript and TypeScript, PEP 8 for
Python, `gofmt` and `rustfmt` conventions for Go and Rust) within 80 columns,
in a readable layout by default and a compact one with `--minify`. The Hspec
suite checks the layout engine, and every acceptance suite compiles and runs
the generated code in both layouts.

The runtimes in `runtime/` are reviewed sources with the same conventions.
After editing one, run `make generate` to embed it, and `make ci` to exercise it
on its target.

## Documentation

The documentation lives in `docs/` and is organized as tutorials, how-to
guides, reference and explanation. `docs/nav.json` lists every page in order.

- Every `lawspec` code block must be a complete unit, starting with `unit`, that
  compiles, or be marked `lawspec fragment`. Each becomes a workbench (below).
  `file=a,b` compiles several files together and shows the last.
  `implementations=acceptance/lessons` attaches, for every language, the
  implementation files that acceptance suite tests for real, found by the
  paths the compiler gives the adapters. `view=implementation` opens on the
  implementation, `target=<language>` selects the language, and `key=<name>`
  names the shared model (by default, the files compiled).
- ```` ```java file=<path> [region=<name>] ```` includes a file as code.
- `::: only java` … `:::` limits text to one lesson track.
- Relative links must resolve.
- Headings use sentence case, with one H1 per page.

`make docs-check` (a CI step) compiles every snippet, including the README's,
and checks every link.

Every `lawspec` block becomes a workbench (`templates/site/playground.mjs`).
For the selected language it lists the specification and the implementation,
both editable, and the generated tests and support code, read-only. **Check**
compiles the specification and lists each law's evidence; **▶ Run** generates
the tests from the current specification and runs them against the current
implementation, for JavaScript and TypeScript, and names the project test
command for the other languages. TypeScript is transpiled in the page by the
vendored TypeScript compiler, loaded on the first TypeScript run; it is not type
checked there (`lawspec-acceptance lessons typescript` type-checks the lesson
implementations with `tsc`). Workbenches with the same key share their files, so a lesson
can edit the implementation in one place and run it in another. Each run
happens in a fresh sandbox: an iframe with
`sandbox="allow-scripts"` (an opaque origin, so no access to the page, its
storage or cookies) and a content security policy that allows only inline and
blob scripts (so no network). The page sends the generated modules, the
implementation, the test shims and the vendored libraries into the frame as
text; the frame links them as blob modules itself. `assets/vendor/sandbox.json`
lists the library modules and the specifiers they are imported by. `lawspec-dev docs` (see `dev/Docs.hs`) renders the pages
through `templates/site/`. The site runs the same `core.wasm` as the npm
package, through a browser launcher with a minimal WASI shim, and runs lesson
tests with fast-check and pure-rand. Code is highlighted with highlight.js
(`templates/site/highlight.mjs` holds the LawSpec grammar, which follows the
VS Code grammar's keywords). Vendored packages are fetched with `npm pack` at
the versions pinned in `docs/vendor.lock.json`, and their integrity is checked
before use.

Build and preview the site:

```sh
make docs
make docs-serve
```

The site is static: `.artifacts/site/` can be served by any web server, and
`_headers` gives Cloudflare Pages the WebAssembly content type and cache rules.
Deploy with Wrangler, after `npx wrangler login` once:

```sh
make docs-deploy
```

This runs `npx wrangler pages deploy .artifacts/site --project-name lawspec-docs --branch main`.
To have Cloudflare build the site instead, it would need GHC and Stack; building
locally and deploying the output is simpler.

## Releasing

See [RELEASING.md](RELEASING.md). Record user-visible changes in
[CHANGELOG.md](CHANGELOG.md).
