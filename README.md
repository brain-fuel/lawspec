# LawSpec

**State the law once. Check it everywhere.**

LawSpec 0.6 compiles reusable laws into native property tests, executable examples,
and implementation adapters. The compiler is Haskell, distributed as prebuilt
WebAssembly with a Node CLI and an asynchronous, typed JavaScript API.

## Portable scalars in 0.7.0

LawSpec now supports fixed and arbitrary integers, exact decimals and rationals,
IEEE floats and complex values, Unicode and raw-text domains, bytes, symbols,
and nested absence states on all seven targets. Integer arithmetic produces representation-independent
`Integer` values; exact division returns Rational. See the [primitive reference](PRIMITIVES.md)
for constructors, arithmetic, native bridges, and machine-width profiles.

Compiler API consumers should read the [schema v2 migration guide](API-MIGRATION.md).
Scalar values use tagged, lossless encodings; generated runtime placement is
separate from artifact ownership. Java 25+ and Python 3.13+ baselines are unchanged.

## Install and try it

Install [LawSpec from npm](https://www.npmjs.com/package/lawspec):

```sh
npm install --save-dev lawspec@0.7.0
npx lawspec --version
```

Node 22+ and the selected target's build tools are required. No Haskell toolchain
is needed to install or run LawSpec. The reference platforms are macOS and Linux.
Use `npx lawspec` to run the locally installed CLI.

To try it in a **new, empty directory**, initialize the starter before installing
local dependencies so LawSpec can create its `package.json` and test script:

```sh
mkdir lawspec-example
cd lawspec-example
npm exec --package=lawspec@0.7.0 -- lawspec init --target javascript
npm install --save-dev lawspec@0.7.0
npx lawspec check
npx lawspec explain 'example.atoi_codec::itoa and then atoi yields a'
npx lawspec doctor
npx lawspec generate
```

In an existing project, install LawSpec first, then run
`npx lawspec init --target javascript`. Existing build files are preserved;
apply the printed dependency and test-runner setup instructions before generation.

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
through compatibility profiles after testing; v0.6's current JVM profile certifies
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
- `explain [unit::law]`: display expansions, example inputs, and expected results.
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
  example `negative integers use a minus sign and round-trip unchanged` is
    x = -42
    expect itoa x = "-42"
    expect atoi (itoa x) = -42
  end
end
```

The implicit prelude defines `left inverse`, `round trip identity is preserved`,
`equivalent`, and `idempotent`.
A law may reference a local reusable law or a prelude law. The compiler performs
capture-avoiding expansion and specializes types; it does not recognize codec
function names specially. `explain` shows the final property:

```text
for all (x :: Int32) . atoi (itoa (x)) = x
```

Reusable laws can declare typed unary function parameters and `requires Eq a`, numeric capabilities such as `requires Integer a`, and
[parameterized refinements and executable contracts](REFINEMENTS.md).
Definitions support law application, function application/composition, universal
quantification, `implies`, Boolean predicates, scalar literals, and equality.
Function signatures and quantified inputs support the [scalar catalog](PRIMITIVES.md),
including mixed and multiple inputs. Generic variables are supported in reusable
laws. Scalar types can also be intermediate or compared results. Functions are synchronous and support curried signatures with any positive
number of scalar arguments. Text literals are double-quoted, with escapes such as `\"`, `\\`,
`\n`, and `\t`; examples must bind each input to a literal of its declared type.
Text values contain Unicode scalar values; surrogate code points are rejected.

Examples refer to the expanded input names, including names inherited from the
prelude. Bind every input exactly once. Ambiguous names and out-of-range values
are errors. Descriptions and rationales use `{function}` references; `{{` and `}}`
produce literal braces. Law blocks use this order:
definition, optional description, optional rationale, examples, optional references.
`--` starts a line comment. Names that cannot be emitted portably are diagnosed.

General collections, external law packages, cross-unit imports beyond the
prelude, async functions, direct existing-symbol binding and browser hosting are
outside this release.

## Algebra and currying (0.6)

Version 0.6 adds algebra laws, scalar law parameters, curried signatures,
and conjunctions.

```lawspec
unit example.addition

add :: Int32 -> Int32 -> Int32

law `addition commutes` is
  definition is
    `commutative` add
  end

  example `3 plus 5 and 5 plus 3 both produce 8` is
    x = 3
    y = 5
    expect add x y = 8
    expect add y x = 8
  end
end

law `zero is an identity on both sides` is
  definition is
    `identity` add 0
  end

  example `zero preserves 3 on either side` is
    x = 3
    expect add 0 x = 3
    expect add x 0 = 3
  end
end
```

Arrows associate to the right and application associates to the left:
`f :: a -> b -> c` takes two arguments, and `f x y` means `(f x) y`.
A partial application such as `add 1` can be passed to a reusable unary law;
`sumFour 1 2` can be passed to a binary law. Partial applications also compose.
The compiler specializes these expressions before emission. Java, Kotlin,
Python, JavaScript, TypeScript and Go adapters take ordinary positional arguments
(`add(x, y)`); Haskell adapters use native currying (`add x y`). Argument order
and types are preserved, including mixtures of `Text`, `Bool` and `Int32`.

Law parameters can also be scalar values: `(e :: a)` supplies an identity and
`(zero :: a)` supplies an absorbing element. Pass literals directly, for example
`left identity` with arguments `add 0`, or `absorbing element` with `multiply 0`.
Functions declared by a unit take one or more scalar inputs and return a scalar;
reusable laws accept these curried functions, their partial applications, and
scalar parameters. Quantified test inputs remain scalar.

The prelude defines the following laws. Every row has an executable example in
[algebra.lawspec](https://github.com/brain-fuel/lawspec/blob/v0.7.0/examples/specs/algebra.lawspec), including both sides of every
combined law. `f` and `g` are binary operations, `inverse` is unary, and `e` and
`zero` are scalar parameters. All these laws require equality of the element type.

| Law and arguments | Equations checked for every quantified input |
| --- | --- |
| `commutative f` | `f x y = f y x` |
| `associative f` | `f (f x y) z = f x (f y z)` |
| `left identity f e` | `f e x = x` |
| `right identity f e` | `f x e = x` |
| `identity f e` | Both identity equations |
| `left absorbing element f zero` | `f zero x = zero` |
| `right absorbing element f zero` | `f x zero = zero` |
| `absorbing element f zero` | Both absorbing equations |
| `left distributive f g` | `f x (g y z) = g (f x y) (f x z)` |
| `right distributive f g` | `f (g x y) z = g (f x z) (f y z)` |
| `distributive f g` | Both distributive equations |
| `idempotent operation f` | `f x x = x` (the existing `idempotent` law is unary) |
| `left inverse element f inverse e` | `f (inverse x) x = e` |
| `right inverse element f inverse e` | `f x (inverse x) = e` |
| `invertible f inverse e` | Both inverse equations |
| `left division f divideLeft` | `f x (divideLeft x y) = y` and `divideLeft x (f x y) = y` |
| `right division f divideRight` | `f (divideRight x y) y = x` and `divideRight (f x y) y = x` |
| `divisible f divideLeft divideRight` | All four division equations |
| `involution f` | `f (f x) = x` |

Here **divisible** means algebraic left/right division. `divideLeft x y` solves
`f x result = y`; `divideRight x y` solves `f result y = x`. The subtraction
example deliberately uses a noncommutative operation: with `x = 3` and `y = 5`,
the left solution is `-2` and the right solution is `8`. Recovery is checked in
both directions. These are total laws; a partially defined division needs an
explicit domain predicate and conditional equations.

`invertible` checks the supplied inverse operation. Check `identity` and
`associative` as well when specifying a group. The prelude states contracts;
it does not supply arithmetic implementations or prove a structure from random
tests. The numeric examples use Int32 arithmetic modulo 2^32 so their laws hold
at overflow boundaries on every target. JavaScript uses `Math.imul` for products,
and Python explicitly wraps results into the signed Int32 range in the test
adapters.

Use `and` to require multiple conclusions in one law. For example:

```lawspec
unit example.absorption
multiply :: Int32 -> Int32 -> Int32

law `zero absorbs on both sides` is
  definition is
    `for all` (x :: Int32) .
      multiply 0 x = 0 and multiply x 0 = 0
  end

  example `3 times zero and zero times 3 both produce zero` is
    x = 3
    expect multiply 0 x = 0
    expect multiply x 0 = 0
  end
end
```

Quantification and implication extend through the following conjunction:
`p x implies A and B` guards both conclusions. Write `(p x implies A) and B`
to guard only the first. A shared guard runs once per check; false guards skip
their entire consequence. Every conjunct is type-checked and emitted. As with
existing assertions, the first failure stops that individual test. `and` is now
a reserved word.

[Currying examples](https://github.com/brain-fuel/lawspec/blob/v0.7.0/examples/specs/currying.lawspec) demonstrate a four-argument
function partially applied twice, a formatter with four heterogeneous arguments,
and composition after partial application. Each example states its exact outputs.
Run `node npm/bin/lawspec.mjs examples` after rebuilding to inspect all nine units
in all seven target languages (126 artifacts).

The expanded API's **`assertion` tree is authoritative**: `AssertEqual` contains
two expressions, `AssertImplies` contains a condition and consequence, and
`AssertAll` contains every conjunct. Existing `left`, `right`, and `guards`
fields are compatibility projections of the first conclusion only; consumers
checking compound laws must traverse `assertion`. Source definitions add `And`.
`lawspec explain` prints the full conjunction and its conditional scope.

## Predicates and conditional laws (0.5)

A predicate is a unary function returning `Bool`. Use `true` and `false` in
expressions, example bindings, and expected results. A Boolean expression can
stand alone as a law's definition: it must evaluate to `true`.

`condition implies consequence` checks the consequence only when the condition
is true. Conditions must have type `Bool`; nested implications short-circuit in
source order. The consequence can be an equality, another implication, a Boolean
predicate, or a reusable law application. Quantify any inputs before using them.

```lawspec
unit example.parse_port

validPort :: Int32 -> Bool
render    :: Int32 -> Text
parse     :: Text -> Int32

law `valid ports round trip` is
  definition is
    `for all` (x :: Int32) .
      validPort x implies
        parse (render x) = x
  end

  example `ordinary port` is
    x = 443
    expect validPort x = true
    expect render x = "443"
    expect parse (render x) = 443
  end

  example `zero is rejected; the round trip is skipped` is
    x = 0
    expect validPort x = false
  end
end
```

The [complete port example](https://github.com/brain-fuel/lawspec/blob/v0.7.0/examples/specs/parse_port.lawspec)
defines valid ports as 1–65535, and covers both endpoints, ordinary ports, zero,
negative values, and 65536. All explicit `expect` assertions run regardless of
the law's condition. A false condition skips only the consequence: invalid ports
never reach `render` or `parse` through the law. Predicate errors still fail the
test; they are not treated as false.

Implication is logical implication, not generator filtering or an assumption.
Randomized tests still sample the full input domain and count a false condition
as satisfying the law. A narrow predicate may therefore exercise few or no
consequences during a random run. Explicit valid examples ensure the important
cases run, and expectations of both `true` and `false` catch always-false and
always-true predicate implementations.

The prelude includes `satisfies predicate` (the predicate holds for every input)
and `left inverse when predicate parse render` (the guarded round trip above).
These reusable laws preserve the condition and its lexical bindings when expanded.
`equivalent` can also compare two predicates, since `Bool` supports equality.
The [Boolean flags example](https://github.com/brain-fuel/lawspec/blob/v0.7.0/examples/specs/boolean_flags.lawspec)
checks that flipping twice restores both `false` and `true`; all targets generate
Boolean property inputs and explicit tests for both Boolean boundary values. Java caps Boolean-only JetCheck runs at the number of
possible input combinations (up to 100), avoiding generator exhaustion.

In 0.5, `implies`, `true`, and `false` become reserved words. Existing 0.4 specs
that use those words as identifiers need renaming. The API adds `BoolLit`,
`Holds`, and `Implies` AST variants, Boolean literal values, and an ordered
`guards` array on expanded laws. `lawspec explain` prints the conditions.

Kotlin adapters now group functions in an `object` named after the unit (for
example, `object ParsePort` in package `example`). This allows both the port and
alternatives units to define `render(Int)`. When upgrading a Kotlin project,
move existing top-level adapter functions into the indicated object; generation
preserves your adapter and reports the required stub shape. Generated tests call
`ParsePort.validPort(...)`, `ParsePort.render(...)`, and `ParsePort.parse(...)`.

## Expected results and migration from 0.3

Every `example` must bind all quantified inputs and then include one or more
`expect <expression> = <literal>` assertions. The expected literal must have the
contextual scalar type of the expression. Expressions can reference the
example's inputs and the unit's functions, including composed function calls.
Input names shadow function names within expectations, following lexical scope.

An example passes only when **all its expected results and its enclosing law**
pass. Expected results are authored specifications, never inferred by executing
your adapter. They apply to that example's inputs; randomized and boundary tests
continue to check the general law. Generated assertions show compared values and
identify the example, input bindings and expression. A failing assertion stops
that individual test; other tests remain independent.

This is an intentional syntax break from 0.3: input-only examples are rejected,
and `expect` is now a reserved keyword. Laws can still omit examples altogether.
For an existing input-only example, retain its bindings and add the intended
result before `end`:

```lawspec
example `zero renders as 0 and round-trips unchanged` is
  x = 0
  expect itoa x = "0"
  expect atoi (itoa x) = 0
end
```

Update every example before running `check` or `generate`. Use
`npx lawspec explain` to inspect the law expansion, example inputs and expected
results; this command displays the specification without executing adapters.
Existing implementation adapters remain user-owned and are never overwritten.
The historical `scratch.md` is a design draft, not the current syntax reference.

## Comparing alternative implementations

`equivalent` compares two functions with the same input and output types. Its
`Eq b` requirement applies to the **result**, so an `Int32 -> Text` comparison
uses text equality, while `Int32 -> Int32` uses integer equality.

```lawspec
unit example.formatting

render :: Int32 -> Text
referenceRender :: Int32 -> Text

law `decimal renderers agree` is
  definition is
    `equivalent` render referenceRender
  end
  example `both renderers produce a negative decimal string` is
    x = -42
    expect render x = "-42"
    expect referenceRender x = "-42"
  end
end
```

This expands to `for all (x :: Int32) . render (x) = referenceRender (x)`.
The example inherits the input name `x` from the prelude. Both functions are
user-owned adapter functions; either may delegate to your existing code.

[The complete example](https://github.com/brain-fuel/lawspec/blob/v0.7.0/examples/specs/equivalent.lawspec) compares decimal
renderers and two implementations that clamp negative integers to zero. For
JavaScript, their adapters can be:

```javascript
export const render = x => String(x);
export const referenceRender = x => x.toString(10);
export const clamp = x => Math.max(0, x);
export const referenceClamp = x => x < 0 ? 0 : x;
```

The same specification generates native tests for all seven targets. The
integration suite checks both examples with matching implementations, then
breaks each alternative separately to verify detection. The general equivalence law alone does not establish independent correctness;
two implementations can share the same bug. Explicit expectations additionally
check the specified outputs at the supplied example inputs. Quantified inputs can use any supported scalar domain.

## Text properties and idempotence

```lawspec
unit example.slug

normalize :: Text -> Text
referenceNormalize :: Text -> Text

law `normalizers agree` is
  definition is
    `equivalent` normalize referenceNormalize
  end
  example `spaces become hyphens; punctuation is preserved` is
    x = "Hello, World!"
    expect normalize x = "Hello,-World!"
    expect referenceNormalize x = "Hello,-World!"
  end
end
```

The [slug example](https://github.com/brain-fuel/lawspec/blob/v0.7.0/examples/specs/slug.lawspec)
compares two implementations of ASCII-space replacement. It includes empty,
Unicode and escaped text. Each target uses its native string generator:
JetCheck `Generator.stringsOf(Generator.asciiPrintableChars())`, Hypothesis `st.text()`, fast-check `fc.string()`,
Rapid `rapid.String()`, Hedgehog `Gen.text`, or Kotest `Arb.string()`.
Generator distributions differ between libraries; the generated tests also
exercise deterministic empty, whitespace, Unicode, combining-mark and escaped
control-character cases. Hedgehog's generated text length range is 0–100.

The prelude's `idempotent` law requires `f (f x) = f x`:

```lawspec
unit example.canonical_url

canonicalize :: Text -> Text

law `canonicalization reaches a fixed point` is
  definition is
    `idempotent` canonicalize
  end
  example `all trailing slashes are removed in one pass` is
    x = "https://example.com/path///"
    expect canonicalize x = "https://example.com/path"
  end
end
```

The [canonical URL example](https://github.com/brain-fuel/lawspec/blob/v0.7.0/examples/specs/canonical_url.lawspec)
uses removal of **all trailing slashes** as a small fixed-point demonstration,
not a complete URL canonicalization algorithm. For JavaScript:

```javascript
export const canonicalize = value => value.replace(/\/+$/, "");
```

Removing just one trailing slash fails the supplied repeated-slash example.
The [mixed-input example](https://github.com/brain-fuel/lawspec/blob/v0.7.0/examples/specs/mixed_inputs.lawspec)
shows `Text` and `Int32` in the same quantified property and executable example.
The JavaScript API represents input bindings and expected values as `number | string | boolean`.
Each example includes `expectations: { actual: Expr; expected: number | string | boolean }[]`.

## Generate all example artifacts

```sh
npx lawspec examples
# Or select a target and a relative output directory:
npx lawspec examples --target java --output example_artifacts
```

This command works without a project configuration or native build tools. It
compiles every bundled example and writes its tests and user-owned stubs to
`example_artifacts/<language>/`, using each target's normal source/test layout.
By default it exports all seven languages; `--json` returns the file inventory.
From a checkout, `make examples` runs the same command.

These are inspection artifacts, not initialized projects: no build files are
created and dependency compatibility is not checked. To run them, configure the
corresponding native project and implement the stubs. Regeneration preserves
user-owned stubs and refuses to overwrite edited generated tests. Each target
has its own ownership manifest. Output paths must be relative and cannot use
parent traversal or symlinks. The default directory is ignored by Git.

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

For contributors working from a repository checkout, build a local archive with
`npm pack ./npm` and install it with `npm install --save-dev ./lawspec-0.7.0.tgz`.
The package payload lives in `npm/`.

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


Refinement predicates can depend on earlier inputs. Generated tests backtrack from
impossible prefixes, preserve the domain during shrinking, and validate function
preconditions and postconditions. `Integer` results specify exact values without
choosing a storage width. See the [refinement reference](REFINEMENTS.md) and
[bundled examples](examples/specs/refinements.lawspec).
