# LawSpec

**State the law once. Check it everywhere.**

LawSpec 0.1 compiles reusable laws into native property tests, executable examples,
and implementation adapters. The compiler is Haskell, distributed as prebuilt
WebAssembly with a Node CLI and an asynchronous, typed JavaScript API.

## Install and try it

The checkout includes the npm package in `npm/`. Build an installable archive:

```sh
npm pack ./npm
npm install --save-dev ./lawspec-0.1.0.tgz
```

No Haskell toolchain is needed to install or run the npm package. Node 22+ and the
selected target's build tools are required. The reference platforms are macOS
and Linux. This checkout has not been published to the npm registry.

From an empty application directory, use the installed `lawspec` command:

```sh
lawspec init --target javascript
npm install
lawspec check
lawspec explain 'example.atoi_codec::itoa and then atoi yields a'
lawspec doctor
lawspec generate
```

Implement `src/example/atoi_codec.mjs`, then run `npm test`:

```javascript
export function itoa(value) { return String(value); }
export function atoi(value) { return Number(value); }
```

The starter adapters intentionally throw until implemented. Generated tests
include the supplied examples, signed 32-bit boundary cases, and randomized
properties with the selected framework's shrinking and failure reporting.

## Targets

| Target | Build setup | Test libraries | Test command |
| --- | --- | --- | --- |
| `java` | Maven, JDK 25, release 25 | JetCheck 0.3.0, JUnit Jupiter 5.14.x | `mvn test` |
| `python` | Python 3.13 or 3.14, pyproject | pytest 8.4.x, Hypothesis 6.135.26+ (6.x) | `python -m pytest` |
| `javascript` | Node 22+, npm, ESM | fast-check 4.x, node:test | `npm test` |
| `typescript` | Node 22+, npm, TypeScript 5.9.x, ESM | fast-check 4.x, node:test | `npm test` |
| `go` | Go modules, Go 1.22–1.26 | Rapid 1.2.0, testing | `go test ./...` |
| `haskell` | Stack, GHC 9.10, LTS 24.58 | Hspec 2.11, Hedgehog 1.5, hspec-hedgehog 0.3 | `stack test` |
| `kotlin` | JDK/JVM 25, Gradle 9.1–9.3, Kotlin 2.3.21 | Kotest 5.9.1 | `gradle test` |

Java 25 and Python 3.13 are the minimum baselines. New JVM releases are admitted
through compatibility profiles after testing; v0.1's current JVM profile certifies
25. Python templates declare `requires-python = ">=3.13"` and runtime checks
currently recognize 3.13 and 3.14. Kotlin templates pin Gradle's supported build
configuration to Kotlin 2.3.21 and target JVM 25.

`npm/compatibility.json` records inclusive minimum/exclusive maximum dependency
bounds. Unknown, prerelease, missing, and incompatible versions fail preflight.
Build-tool probes inspect resolved dependencies, compiler settings, source roots,
and runner configuration. Unverifiable custom filtering/configuration is rejected
with setup instructions. Build tools may populate their normal caches while
resolving dependencies; LawSpec does not run dependency installers during generation.

## Existing projects and configuration

`init` creates `lawspec.json` and a starter specification. It creates build
files only when no existing build setup is detected. Existing build files are
preserved, and setup instructions describe the changes you need to make yourself.

```json
{
  "version": 1,
  "sources": ["laws"],
  "targets": [
    {"language": "java", "root": "java"},
    {"language": "python", "root": "python", "python": ".venv/bin/python"},
    {"language": "haskell", "root": "haskell"}
  ]
}
```

Source entries are files or directories, relative to the configuration file.
Directories are scanned for `.lawspec` files. Every target has its own project
root. Use `init --target python --project python` to add a target; `--config`
selects a different configuration file. Targets can override `sourceDir` and
`testDir` with relative paths. Configure the native build to include those paths
before generation. Go's source and test directories must be the same.

Defaults are `src`/`test` for JS, TS and Haskell; `src`/`tests` for Python;
`src/main/java`/`src/test/java` for Java; the corresponding Kotlin directories;
and unit-based package directories at the Go project root. Python accepts a
`python` interpreter override; Java accepts `maven`; Kotlin accepts `gradle` and
otherwise uses a local `gradlew` or `gradle` on PATH.

For Python, create and select a 3.13+ virtual environment and install the printed
test dependencies. For Stack, run `stack build --test --no-run-tests` once before
`doctor`; this resolves the snapshot and generates the Cabal description through
Hpack. Doctor uses that existing description without rewriting it. Test discovery
uses `test/Spec.hs` with `hspec-discover`.

Commands:

- `check`: parse, resolve, type-check and expand laws without target dependencies.
- `explain [unit::law]`: display expansion steps and inherited example inputs.
- `doctor`: inspect selected native environments and print corrective instructions.
- `generate`: check environments, validate every output, then write artifacts.
- `generate --dry-run`: show proposed file operations without applying them.
- `generate --check`: fail when generated files need updating, without writing.

Use `--target <language>` to select a configured language, and `--json` for
machine-readable check, explanation, doctor and generation output. Generation
fails before writing if any selected target is incompatible or any output
conflicts with file ownership.

## Language slice

```lawspec
unit example.atoi_codec

itoa :: Int32 -> Text
atoi :: Text -> Int32

law `round trip` is
  definition is
    `left inverse` atoi itoa
  end
  description is
    "applying {itoa} and then {atoi} recovers the original integer"
  end
  example `negative` is
    x = -42
  end
end
```

The implicit prelude defines `left inverse` and `round trip identity is preserved`.
A law may reference a local reusable law or a prelude law. The compiler performs
capture-avoiding expansion and specializes types; it does not recognize codec
function names specially. `explain` shows the final property:

```text
for all (x :: Int32) . atoi (itoa (x)) = x
```

Reusable laws can declare typed unary function parameters and `requires Eq a`.
Definitions support law application, function application/composition, universal
quantification, integer literals and equality. Function signatures use `Int32`
and `Text`; generic variables are supported in reusable laws. v0.1 generates
quantified `Int32` inputs, including multiple inputs. `Text` can be an intermediate
or compared result. Functions are synchronous and unary.

Examples refer to the expanded input names, including names inherited from the
prelude. Bind every input exactly once. Ambiguous names and out-of-range values
are errors. Descriptions and rationales use `{function}` references; `{{` and `}}`
produce literal braces. Metadata blocks follow the order shown in `scratch.md`:
definition, optional description, optional rationale, examples, optional references.
`--` starts a line comment. Names that cannot be emitted portably are diagnosed.

Additional primitives, external law packages, cross-unit imports beyond the
prelude, async functions, direct existing-symbol binding and browser hosting are
outside this release.

## Ownership

Implementation adapters are created once and belong to you. Implement them or
have them delegate to existing application functions. Regeneration never rewrites
them. If the required adapter contract changes, generation prints the new stub
shape for you to apply manually.

Generated tests are tracked in `.lawspec/generated.json` with content hashes.
Commit that manifest alongside generated tests. LawSpec refuses to overwrite
unowned files or edited generated files, even if an unowned file has matching
contents. Obsolete tests are deleted only when they still match their recorded
hash. User adapters remain. Output paths cannot traverse outside a target root
or pass through symlinks. Writes use temporary files and atomic replacement;
concurrent edits detected during preflight abort generation.

## JavaScript API

```javascript
import { createCompiler } from 'lawspec';

const compiler = await createCompiler();
const result = await compiler.planGeneration({
  sources: [{ path: 'codec.lawspec', content: sourceText }],
  target: 'python'
});
if (result.diagnostics.length) console.error(result.diagnostics);
else console.log(result.files);
```

`check`, `expand`, and `planGeneration` are asynchronous and share structured
source/diagnostic types. `planGeneration` returns proposed paths, contents and
ownership; it does not inspect a host environment or write files. The CLI applies
compatibility and ownership checks. TypeScript declarations ship in the package.
The same compiler instance supports repeated and concurrent requests, serialized
by the JS shim.

## Build and verify

```sh
stack test
# With wasm32-wasi-cabal and wasm32-wasi-ghc installed:
tools/wasm.sh
node --test npm/test/*.test.mjs
node tools/parity.mjs
node tools/build-integrity.mjs
node tools/package-smoke.mjs
```

Stack is the native development tool. The WASM build uses GHC's wasm32-wasi backend
and Cabal, following Rice's Tax. `tools/wasm.sh` reads `~/.ghc-wasm/env` when present.
The current artifact was built using GHC WASM 9.14.1.20260731; WASM dependencies
are frozen in `wasm/cabal.project.freeze`. Install the cross compiler through
[ghc-wasm-meta](https://gitlab.haskell.org/haskell-wasm/ghc-wasm-meta).

Haskell's export table generates the JS API and `.d.ts` files. The build records
compiler-source and artifact hashes in `npm/build.json`; CI rejects stale WASM
or hand-edited generated wrappers. The npm archive is a self-contained consumer
artifact, with no install-time compilation or download hook.

For all seven native integrations, install their build tools, then:

```sh
# Set LAWSPEC_GRADLE to a Gradle 9.3.0 executable if it is not on PATH.
node tools/bootstrap-integration.mjs
node tools/integration.mjs
```

These scripts use isolated `.integration/` projects. Bootstrap installs the pinned
test dependencies; integration verifies that correct adapters pass, broken adapters
fail, regeneration preserves implementations, and generation leaves build files
unchanged. Arguments select individual targets. `LAWSPEC_PYTHON=3.14` selects the
additional Python reference environment. CI also exercises Node 22/24/26 and packs
and installs the npm archive. Registry publication is a separate release action.
