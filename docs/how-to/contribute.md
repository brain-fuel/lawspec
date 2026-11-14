---
id: lawspec.how-to.contribute
kind: how-to
title: Contribute to LawSpec
---
# Contributing to LawSpec

This guide is for working on LawSpec itself. To use LawSpec, see the
[documentation](../index.md).

## Repository layout

| Directory | Contents |
| --- | --- |
| `src/` | The compiler library: parser, imports, inference, elaboration, Core, prover, testing planner and the 17 target emitters. |
| `app/` | `lawspec-core`, the native compiler executable. It reads a JSON request on standard input and writes the result. |
| `dev/` | `lawspec-dev`: repository checks (`boundaries`, `integrity`), code generation, and the local CI driver. |
| `acceptance/` | `lawspec-acceptance` and its suites, which run the bundled examples on every target. |
| `bench/` | Benchmarks of generated code: a fixture and a native driver per target, run by `lawspec-dev bench`. |
| `test/` | The Hspec test suite, `lawspec-test`, and its fixtures. |
| `npm/` | The npm package payload: the Node CLI, API wrapper, WASM core and bundled examples. |
| `runtime/` | Target runtime sources, embedded into the compiler and emitted into generated projects. |
| `examples/` | Example specifications, the native-binding payment projects, and the package example. |
| `editors/vscode/` | The syntax-highlighting grammar and VS Code extension. |
| `wasm/` | The Cabal project that builds the compiler for WebAssembly. |
| `templates/` | The sources of every JavaScript file in the repository, and of the documentation site. |
| `tools/` | Build and integration scripts, generated from `templates/tools/`. |
| `docs/` | The documentation site. |
| `to_be_removed/` | Plans and records with no canonical home yet, waiting to be folded into the ledger and deleted. |

The root also holds canon's files: `canon.yaml` (its configuration),
`canonical_refs.yaml` (the reference registry), `canonical_decisions.yaml`
(the decision ledger), `canonical_exemptions.yaml` and `canonical_vetting/`
(see [the canonical format](#the-canonical-format)).

## Building

Stack is the native development tool:

```sh
stack --no-terminal build --test --no-run-tests
stack --no-terminal test
```

To try a request against the native compiler:

```sh
printf '%s' '{"schemaVersion":5,"languageProfile":"1.0-rc.2","verification":{"layers":[]},"method":"check","sources":[{"path":"x.lawspec","content":"unit example.empty"}]}' | stack exec lawspec-core
```

### WebAssembly

The npm package ships the compiler as WebAssembly, built with GHC's wasm32-wasi
backend and Cabal. Install `wasm32-wasi-ghc` and `wasm32-wasi-cabal` through
[ghc-wasm-meta](https://gitlab.haskell.org/haskell-wasm/ghc-wasm-meta), then:

```sh
tools/wasm.sh
```

The script reads `~/.ghc-wasm/env` when present. Every worktree builds into
the same wasm32-wasi Cabal store, so the script holds a machine-wide lock
(`locks/wasm.lock` in the [shared development cache](#the-shared-development-cache))
and a second build waits for the first. It builds the WASM core and
its JavaScript glue, stages the package files in `npm/`, and records compiler
source and artifact hashes in `npm/build.json`. WASM dependencies are frozen in
`wasm/cabal.project.freeze`. The npm archive is self-contained: no install-time
compilation or download.

`npm/host-component/` is a build product that git ignores, and `integrity`
fingerprints its files, so a new worktree has none until `make component`
builds it. The target installs the packed Wasm Platform Kit from
`~/para/projects/wasm-platform-kit/dist` (`make component SDK_DIST=<directory>`
names another), builds the component under the same machine-wide lock as
`tools/wasm.sh`, packages this machine's native artifact, and records the
fingerprints in `npm/build.json`. Packaging rewrites
`component/native-packages.json` with the platforms built here, so the
target restores the committed record afterwards; pass `KEEP_NATIVE_RECORD=1`
to keep the rewritten file when a release is being prepared. See
[the component build instructions](../../component/README.md) for the steps
one by one.

To build and install a local archive:

```sh
npm pack ./npm
npm install --save-dev ./lawspec-0.34.0.tgz
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
stack run lawspec-dev -- ci --jobs 4                 # at most four steps at once
stack run lawspec-dev -- ci --jobs 1                 # one step at a time
stack run lawspec-dev -- ci --no-core --target go    # one target's steps, without the compiler checks
stack run lawspec-dev -- ci --only 'rust-*'          # steps by name, with the steps they follow
stack run lawspec-dev -- ci --affected               # steps that read what changed since main
stack run lawspec-dev -- ci --affected --list        # name them; run nothing
```

`make ci` is equivalent to the first form. The check runs the compiler, npm,
native/WASM parity, package and editor checks. Then, for each target, it
bootstraps the pinned test dependencies, runs every acceptance suite in both
machine profiles, and runs the installed native-binding example. Each step logs
to `.artifacts/ci/<step>.log`. Every step runs even after a failure unless
`--fail-fast` is given, and the command exits non-zero if any step failed.

Each step that finishes also appends a line to `.artifacts/ci/timings.jsonl`:
its name, when it started, its seconds, whether a recorded pass stood in for
it (`cached`), and whether it passed. Compare two runs from that file.

Steps run in parallel: `--jobs N` at a time, or `LAWSPEC_CI_JOBS`, or the
machine's job budget. The budget is half the machine's processors
(`LAWSPEC_CI_MACHINE_JOBS` sets it) and is shared by every run on the
machine, in any worktree: a step holds one of its slots while it runs, so two
runs together use the processors one would. The console prints a line as each step finishes, so
lines come in the order steps finish; on a terminal a status line also shows
the steps still running. The summary names failed steps in step order.
`--jobs 1` runs the steps one at a time, in a fixed order, as before.

Parallel steps never share what one of them changes. Each step declares the
steps it follows and the resources it holds, and a step starts only when
those have finished (passed or failed) and nothing running holds its
resources exclusively:

- A target's environment in `.integration/<target>` is written by its
  bootstrap (and, for Erlang, Elixir and Gleam, by the property-framework
  steps) and only read by its suites, which follow the bootstrap.
- Each acceptance suite holds its project directory,
  `.artifacts/<suite><profile>/<target>`. Suites for one target run together,
  each in its own project.
- The `build` step builds the library, the executables and the test suite
  once, and nothing that runs them starts before it. Every other step uses
  `stack exec`. Switching between `stack test` and `stack run` recompiles the
  library, so no step does either.
- The compiler's tests run from the built test executable in five parts
  (`compiler-tests-proof-receipts`, `-smt-text`, `-test-manifest`,
  `-generation` and `-rest`). The last part skips what the others select, so
  a new test group runs there without being listed. `sh
  tools/compiler-tests.sh --match "SMT text"` runs one part by hand.
- Each file in `npm/test` is a step, `npm-test-<name>`.
- Native/WASM parity runs as seven steps, `parity-<part>`
  (`node tools/parity.mjs --part=frontend-32` runs one). In one process it
  took 113 minutes.
- Haskell and Java suites follow the target's `crypto` suite, which fills
  Stack's snapshot database and Maven's repository alone; neither guards
  concurrent installation. Cargo, Go, Gradle, NuGet and npm lock their caches.
- Suites that wait on the real clock (actors, sessions, distribution and the
  BEAM network, remote, session and mailbox APIs, scheduling, resilience,
  consistency, concurrency) are a timing class: at most a third of the jobs
  run them at once.
- `component-native-acceptance` runs first and alone, in its run and on the
  machine: it holds every slot of the job budget.
- The Haskell, Java and Clojure warm-up suites also hold a machine-wide lock
  each (Java and Clojure share Maven's), so two runs never fill Stack's
  snapshot database or the Maven repository at once.

The slots and locks are advisory file locks in the shared development cache.
The system releases them when their holder exits, so a run that crashes or is
killed leaves nothing held.

### Choosing steps

`--only <glob>` runs the steps whose names match (`*` is any run of
characters, `?` any one; repeat the option for several patterns).
`--affected [<base>]` runs the steps that read a file that differs from the
base: by default the commit where the branch left `main`, with uncommitted
and untracked files counted. Together they run the named steps that are
affected. `--no-core` leaves out the compiler, npm and editor steps, as
`--core` leaves out the targets'; the `build` step stays, since every suite
runs what it builds.

Both selections also run the steps the selected ones follow, such as a
target's bootstrap and `build`, since a suite without them checks
nothing; `--exact` runs the selection alone. `--list` prints the steps that
would run.

What a step reads is declared in `dev/Ci.hs`: `stepInputs` for the steps
whose passes are recorded, and `suiteReads` for acceptance suites (the
compiler sources, the harness, the suite's own directory without the other
targets' adapters, the specifications its manifest names, and the pinned
locks). A step that declares nothing may read anything, so any change selects
it. The target bootstraps and the tool-driven integration steps are in that
class; `--core` or `--only` narrows them further. `--affected` chooses what to
run while working. It does not replace the complete check before a release.

A step that runs past two hours is stopped and fails;
`LAWSPEC_CI_STEP_MINUTES` changes the limit. On macOS the check holds an
idle-sleep assertion (`caffeinate -i`) until it exits, since a sleeping
machine stops every step.

Ctrl-C stops every running step and everything it started. To add a step,
declare what it follows and holds in `plan` in `dev/Ci.hs`.

Results are content-addressed, so a second run only repeats what changed:

- Each acceptance run is keyed by the project it generates, the suite's
  adapters, stubs and mutants, the harness, and the toolchain's versions,
  dependency locks and environment. A compiler change that leaves a target's
  generated files unchanged reuses that target's results; the console marks
  them `(cached)`.
- The compiler, parity, package, docs and Rust runtime steps are keyed by the
  bytes of the repository files they read (tracked or untracked, not ignored)
  and their tools' versions, and print `cached`. `package-smoke` is keyed on
  what npm packs from `npm/`.
- An `npm-test-<name>` step is keyed the same way, by what that file can
  read: `npm/` without the other test files, the environment locks, each
  repository root that the file, a test helper or an SDK module names as a
  path, and the Haskell sources only if the file names `stack`, GHC or one of
  the repository's executables. The key also holds the presence and version
  of every tool a test may start and the bootstrapped environments. Editing
  one test file reruns that file; editing documentation or an acceptance
  suite reruns none. These inputs are declared, not observed: a test that
  reads a root through a computed path must name it in a string, or
  `sdkTestInputs` in `dev/Ci.hs` must add it.
- What `package-smoke` and the SDK tests resolve from package registries is
  in no key, which is one reason a release runs `--fresh`.
- The keys hold only the environment variables that change what a check does
  (`effectiveEnvironment` in `tools/ci-artifact-key.mjs`), so a pass recorded
  in one terminal or worktree is reused in the next.

`--fresh` (or `make ci-fresh`) runs everything, as a release does.
Fresh runs still record their passes. For a single `lawspec-acceptance` run,
`LAWSPEC_CACHE=refresh` reruns and records, and `LAWSPEC_CACHE=0` turns the
cache off.

### The shared development cache

Passes are recorded in one directory for the machine, `~/.cache/lawspec-dev`
or `LAWSPEC_DEV_CACHE`, which every worktree shares:

| Path | Contents |
| --- | --- |
| `ci/` | Recorded passes of the core steps |
| `acceptance/` | Recorded passes of acceptance runs |
| `formatted/` | Files a pinned formatter has already passed, by content |
| `npm/`, `go-build/` | npm's and Go's caches for the integration tools |
| `jobs/`, `locks/` | The job budget's slots and the machine-wide locks |

A key holds no path of the worktree it was computed in: files enter it by
their paths from the repository root, tools by their versions (and, for the
compiler tests, their bytes), and of the environment only the variables that
change what a check does. So a second worktree at the same content reuses the
first one's passes, and a new terminal does not change a key. Records are
written beside their final name and renamed into place, so concurrent runs
never read half a record.

An acceptance project's native build output (`target`, `.build`,
`.stack-work`) is removed once its pass is recorded; the sources, logs and
reports stay in `.artifacts/<suite><profile>/<target>`. Set
`LAWSPEC_KEEP_BUILD=1` to keep the build output while working on one suite.
A recorded pass is reused without writing or building the project.

```sh
make clean       # remove build output under .artifacts; keep recorded passes
make clean-all   # also forget every recorded pass, for all worktrees
```

These run `lawspec-dev clean --artifacts [--keep-cache]`. Neither removes
`.integration/` or the tools' download caches.

### Inner loops

The complete check takes hours. While working, run what the change can
affect, and leave the complete check for the merged branch.

| Change | Check |
| --- | --- |
| The Node host (`templates/npm/`, then `make generate`) | `stack run lawspec-dev -- ci --core --affected`. No acceptance suite reads the host, except the `packages` suite, which loads package manifests through it. |
| One emitter or runtime (`src/LawSpec/<Target>*.hs`, `runtime/`) | `stack --no-terminal test`, then `stack run lawspec-dev -- ci --no-core --target <target>`. Suites whose generated project did not change answer from recorded passes. |
| One acceptance suite (`acceptance/<suite>/`) | `stack run lawspec-acceptance -- <suite> <target>`, or `stack run lawspec-dev -- ci --affected` for every target and profile of it. |
| The language (parser, inference, Core, prover) | `stack --no-terminal test`, then `stack run lawspec-dev -- ci --affected`: every suite is selected, and those whose generated projects are unchanged are answered from recorded passes. |
| Documentation (`docs/`, `README.md`) | `stack run lawspec-dev -- ci --only docs --only rejection-examples` (`make docs-check` is the first of these). |
| The CI driver or harness (`dev/`, `acceptance/*.hs`) | `stack run lawspec-dev -- ci --only 'ci-*'`, then one cheap suite such as `stack run lawspec-acceptance -- domain javascript`, twice: a run, then a recorded pass. |

After a change to `src/` that the WASM core must carry, `integrity` and the
`parity-*` steps need `make wasm` first; `--affected` selects them but cannot build it.

Smaller checks:

```sh
stack --no-terminal test                        # compiler tests
node --test npm/test/*.test.mjs                 # npm package tests
stack run lawspec-dev -- boundaries             # Core and emitters never import syntax or inference
stack run lawspec-dev -- integrity              # build fingerprints and staged copies
node tools/parity.mjs                           # native and WASM output agree
node tools/parity.mjs --canonical examples/rc1/parcel-measurements.lawspec
node tools/package-smoke.mjs                    # pack, install and use the archive
node tools/package-smoke.mjs --examples         # and export every bundled example (releases)
```

`make test`, `make check` and `make package` group these.

The parity command uses the ordinary current compiler API for bundled or
explicitly named specifications. Its counts distinguish accepted responses from matching rejections, and
every target must emit the reference codec at both widths and layouts. Package
checks load the canonical example's complete dependency graph, including both
tax-package versions.

Benchmarks measure the generated code itself:

```sh
stack run lawspec-dev -- bench kafka                    # Rust, Go, Java and Kotlin
stack run lawspec-dev -- bench kafka --scale 10000 go   # a smaller workload, one target
stack run lawspec-dev -- bench kafka --typed            # what stays on the dynamic path
stack run lawspec-dev -- bench compile 100 200 400      # the compiler, on scaled models
```

`lawspec-dev bench <name>` generates `bench/<name>/bench.json`'s specs and
packages for each target into `.artifacts/bench/<name>/<target>`, copies the
driver in `bench/<name>/<target>/` over it, builds it, and runs it under
`/usr/bin/time -l`. It prints each phase's operations per second, the memory
the driver reports, and the peak resident set, and writes the summary to
`.artifacts/bench/<name>/<target>.txt`. The `kafka` benchmark drives a copy of
LawTwin's Kafka reference model; see
[Embed a generated model](embed-a-generated-model.md). `bench compile` times
`check` on a model shaped like an imported API description, N record types
and a state of N maps with two failing definitions per type, so a change
that makes checking grow faster than the program shows.

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
A passing run is recorded in the [shared development cache](#the-shared-development-cache);
the same run again prints its lines with `(cached)` and writes nothing.

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
- `LAWSPEC_JAVA_RELEASE=21` compiles and tests the Java target at release 21:
  the scaffold's `maven.compiler.release` and the request's `release`. A suite
  that imports `lawspec.crypto` or `lawspec.network` is refused there, with
  the `release` diagnostic.
- `LAWSPEC_JUNIT=6.0.3` tests the Java target on that JUnit Jupiter release in
  place of the scaffold's 5.14.0. Run the Java suites with it before widening
  the range in `templates/npm/compatibility.json`. Neither variable is part of
  `lawspec-dev ci`.
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
usual style (Google style for Java, Kotlin, JavaScript and TypeScript, `ruff
format` for Python, `gofmt` and `rustfmt` conventions for Go and Rust), from the
target's profile in `LawSpec.Code.Doc.styleFor`, in a readable layout by default
and a compact one with `--minify`. The Hspec suite checks the layout engine,
and every acceptance suite compiles and runs the generated code in both layouts.
For a target held to its canonical formatter (Python and Go so far),
acceptance also runs the formatter's check mode on the generated project; any
difference fails.

The runtimes in `runtime/` are reviewed sources with the same conventions.
After editing one, run `make generate` to embed it, and `make ci` to exercise it
on its target.

## Documentation

The documentation lives in `docs/` and is organized as tutorials, how-to
guides, reference and explanation. Every page begins with front matter naming
its `id`, its `kind` (`tutorial`, `how-to`, `reference` or `explanation`,
matching its directory; the landing page `docs/index.md` is `index`) and its
`title`:

```yaml
---
id: lawspec.how-to.contribute
kind: how-to
title: Contribute to LawSpec
---
```

The title lives only there. `docs/nav.json` lists every page in order, by
`path` alone; a section without a page of its own names a `title`, and a
lesson track a `track`.

- Every `lawspec` code block must be a complete unit, starting with `unit`, that
  compiles, or be marked `lawspec fragment`. Each becomes a workbench (below).
  `include=a,b` compiles several files together and shows the last.
  `implementations=acceptance/lessons` attaches, for every language, the
  implementation files that acceptance suite tests for real, found by the
  paths the compiler gives the adapters. `view=implementation` opens on the
  implementation, `target=<language>` selects the language, and `key=<name>`
  names the shared model (by default, the files compiled).
- ```` ```java include=<path> [region=<name>] ```` includes a file as code.
  `file=` is left to canon, for a block that tangles into a source file.
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

## The canonical format

LawSpec follows [canon](https://github.com/brain-fuel/canon)'s canonical
format, so every fact about the project has one home ref:DEC-canonical-format.

- **Why** a unit exists is its canonical comment, in its language's
  documentation form: Haddock `-- |` above a module or a top-level signature,
  a docstring in Python, JSDoc or TSDoc, a Go doc comment, Javadoc, KDoc, or
  rustdoc. The name says what the unit does; the comment says why, and cites
  its reasons as `ref:KEY`.
- **A cited work** is an entry of `canonical_refs.yaml`, with a kind, a title
  and a locator. A test cites the `requirement` entry it verifies: each Hspec
  module's spec is a `test_` function whose comment names its requirement.
- **A decision** is an entry of `canonical_decisions.yaml`, open with a
  `revisit` version or decided with its answer. Release notes say what
  changed; explanation pages explain and cite the decision.
- **A page** is a Folio page under `docs/`, with front matter.
- **Anything else** waits in `to_be_removed/` until it has a home.

`canon ingest` records every comment, page, decision and reference in
`canonical_vetting/` as `pending`; a person sets each verdict to `good`, `bad`
or `deferred` and commits it, and git records who signed. A subject whose debt
is not yet due is listed in `canonical_exemptions.yaml` with the version to
revisit it by.

canon reads the grammars of a canon checkout. Build one, then point
`CANON_HOME` at it:

```sh
git clone https://github.com/brain-fuel/canon && (cd canon && stack build)
export CANON_HOME=$PWD/canon
make canon                                  # canon check
stack run lawspec-dev -- canon ingest       # record new material as pending
stack run lawspec-dev -- canon vet          # list what needs a verdict
```

`lawspec-dev canon` links `.canon` to the checkout, whose grammars
`canon.yaml` names, and runs its binary (or `CANON`, if set). The complete
check runs `canon check` as its `canon` step, and skips it with a message when
`CANON_HOME` is not set. ref:DEC-canon-from-a-checkout `canon.yaml` names under
`canon` the canon version the vetting files were written with; use a checkout
of that version. Verdicts are given on Rice's Tax's review page, `make tax`;
see [Vet the canonical material](vet.md).

## Releasing

See [the release guide](release.md). Record user-visible changes in
[CHANGELOG.md](../../CHANGELOG.md).
