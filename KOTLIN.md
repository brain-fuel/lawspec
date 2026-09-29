# Native Kotlin data

LawSpec 0.9 emits Kotlin sealed interfaces and named generic variant classes from
checked Core declarations. Generated schemas and codecs share the JVM scalar
runtime, independently of Kotest.

```lawspec
unit example.trees

type Tree (a :: Type) is
  Leaf value :: a
  Branch children :: List (Tree a)
end

echo :: Tree Int8 -> Tree Int8
```

The public type is `lawspec.data.Tree<Byte>`. Its variants are
`Tree.LeafCase<Byte>`, with a typed `value` property, and
`Tree.BranchCase<Byte>`, with `children: List<Tree<Byte>>`. Recursive and mutually
recursive fields retain native types. Generic parameters also remain on nullary
variants. Empty types have a private constructor and cannot supply generated
arguments, but can occur inside inhabited types such as `Maybe Empty`.

A correct adapter is:

```kotlin
fun echo(value: lawspec.data.Tree<Byte>): lawspec.data.Tree<Byte> = value
```

Adapter files remain user-owned. Duplicate type names across units receive
qualified generated names. Kotlin built-ins are qualified in generated signatures
to avoid shadowing by domain types. Adapters that collide with generated JVM
runtime classes are rejected before output.

## Containers and absence

`List a` uses Kotlin `List<T>`. `Maybe a` uses `LawSpecRuntime.Maybe<T>` with
`Nothing<T>` and `Just<T>`. `Either a b` uses `LawSpecRuntime.Either<L, R>` with
`Left<L, R>` and `Right<L, R>`.

Interoperability absence remains separate:

- `Nullable a`: `LawSpecKotlin.Nullable<T>`, with `Null<T>` and `Present<T>`.
- `Optional a`: `LawSpecKotlin.Optional<T>`, with `Undefined<T>` and `Present<T>`.
- `Null` and `Undefined`: distinct singleton support values.
- `Unit`: Kotlin `Unit`, including adapter operations without a meaningful result.

These representations preserve every state of `Nullable (Optional a)` and other
nested combinations. Checked codecs validate both native adapter arguments and
results. Containers and raw arrays are copied across the logical/native boundary.
LawSpec equality is schema-directed, including IEEE component equality and
Symbol identity; generated variant classes do not substitute Kotlin data-class
equality for those rules.

## Scalars

Fixed signed integers use Kotlin `Byte`, `Short`, `Int`, and `Long`. UInt8,
UInt16, and UInt32 use the next sufficiently wide signed JVM type. UInt64,
arbitrary integers, and machine-profile integers use `BigInteger` with explicit
domain checks. These portable machine-profile representations do not bind a
host machine-sized primitive.

An adapter whose result is the abstract `Integer` returns Kotlin `Number`.
`Integer` is the top of the integral tower, so an implementation may return
`Int`, `Long` or `BigInteger`; the result bridge rejects non-integral values
such as `Double` and checks the logical domain. Arguments remain `BigInteger`.

Decimal uses exact `BigDecimal`; Rational uses the normalized
`LawSpecRuntime.Ratio`. Complex components use `LawSpecRuntime.Complex`, with
Float32 precision validated for Complex64. Raw code-point text uses `IntArray`,
raw UTF-16 uses `String`, and bytes use `ByteArray`. `Char` uses a one-scalar
`String`, allowing supplementary characters; `CodePoint` uses `Int` and
`CodeUnit16` uses Kotlin `Char`.

`LawSpecKotlin.Symbol` preserves the underlying fixture identity through checked
round trips. Its native equality compares that identity, so two Symbols with the
same description remain distinct.

## Total definitions

Checked source definitions produce native Kotlin entry points and shared Java
implementation bodies in source directories. Neither requires Kotest. For example:

```lawspec
unit example.total

definition increment (value :: Int8) :: BigInt is
  value + 1
end
```

The native call is `lawspec.definitions.example.Total.increment(symbols, value)`;
`value` is a Kotlin `Byte`, the result is `BigInteger`, and `symbols` is a
`MutableMap<String, Any>` shared by calls in one example. An input of 127 returns
128. Native signatures retain typed lists, custom variants, and nested presence
payloads. Checked codecs validate inputs and results; failures include the
resolved definition name.

Properties call the generated implementation directly. Definitions never become
user-owned adapter stubs. Recursive definitions must pass the frontend's
structural termination and definedness checks. Generic definitions specialize to concrete uses. Refined signatures become
checked contracts, and refinement predicates may call checked definitions.

`tools/kotlin-definitions-integration.mjs` checks both machine profiles, standalone
source calls, native type errors, recursive properties, incorrect adapters,
compact source and complete minified generation plans, custom layouts, and
regeneration protection. Java implementation
bodies are checked against Google Java Format; Kotlin uses structured document
layout checked by the independent compiler-parser audit described below.

## Generated tests

Native declarations, schema metadata, and codecs belong in source directories.
`LawSpecStrategies` and `LawSpecKotlinStrategies` belong in test directories and
compose Kotest arbitraries and shrink trees. Bounded recursive generation reserves
each product field's minimum cost before distributing remaining nodes. Dependent
generation retains source shrink trees, including list lengths and constructor
choices, which Kotest 5.9's flatMap otherwise discards.

`tools/kotlin-data-integration.mjs` checks native declarations, codecs, and
shrinking in readable/compact layouts. `tools/kotlin-data-properties.mjs` compiles
and runs actual compiler output through Kotest with correct and incorrect
adapters, both profiles, and custom source/test roots. It accepts
`LAWSPEC_MINIFY=1` and includes the shared arithmetic conformance vectors in its
scalar scenario. The refinements scenario checks dependent domains, guarded
arithmetic, standalone contracts and four faulty adapters. It uses cached
compiler/library dependencies directly.

Generated property files now use structured documents throughout: imports,
helpers, examples, boundaries, native Kotest strategies, dependent refinement
domains, guarded assertions and contract wrappers. Blocks use two-space
indentation and continuation arguments use four spaces. Checked native codecs,
short-circuiting, Symbol context, single-evaluation matches and framework
generation/shrinking remain intact. The corpus audit below covers both machine
profiles and readable/compact syntax equivalence.


For internal checked Core definitions, shared JVM implementation bodies now
prove attached contracts before emission and enforce ordered preconditions and
validated-result postconditions at runtime. Native wrappers and direct logical
entry points both use those checks. `tools/jvm-definition-contract-integration.mjs`
verifies both JVM languages, profiles and layouts without a test-framework
dependency, including corrupted-result rejection. Refined source signatures
now produce these contracts through template proof and specialization.

## Source formatting and independent parsing

Kotlin output follows the published [Google Android Kotlin style guide](https://developer.android.com/kotlin/style-guide):
four-space blocks and wrapped arguments/parameters, with a 100-column code limit.
This corrects the earlier two-space Kotlin layout. Java support files continue to
use Google Java Format conventions. Python independently follows PEP 8.

`tools/kotlin-formatting-integration.mjs` generates the bundled corpus and the
total-definition fixture in both machine profiles and formatting modes, plus both
Gradle Kotlin scaffold files. An
independently installed Kotlin compiler parses both outputs. The checker compares
syntax trees, retaining operators, declaration modifiers, type arguments, and
string-template contents; it ignores whitespace, comments, semicolons and optional
trailing commas. Negative fixtures distinguish changed signs, val/var, string
contents and escaped dollars from template interpolation.

The audit also checks block/argument indentation, line lengths, tabs, trailing
whitespace, explicit ASCII-sorted imports, breaks after binary operators,
multiline conditional/when braces, and loop braces. Set `LAWSPEC_CORE` to the native compiler and optionally set
`LAWSPEC_KOTLIN_HOME` to a Kotlin installation containing `lib/kotlin-compiler.jar`.
The tool detects ordinary and Homebrew installations of `kotlinc`. Positional
arguments select specification files. All parser and formatting tooling remains
development-only; generated projects do not download it.

The audit checks the rules listed above. It does not compare byte-for-byte with
an external Kotlin formatter. No formatter is required to generate projects.


## Constructor contracts

Kotlin data emission uses profile-aware typed JVM schema callbacks.
Generated named codecs and native definition arguments/results preserve a caller's
Symbol context through nested List, Maybe, Either, Nullable and Optional values.
Kotlin-specific construct/match helpers also accept an explicit context; existing
Kotlin calls retain overloads or default arguments. Scalar-only bridges remain
framework-independent.

`tools/kotlin-constructor-native-integration.mjs` compiles and executes dependent
fields, generic/refined lists, sums, guarded arithmetic, machine ranges, nested
absence, fixture Symbols and raw UTF-16 units at both widths and layouts. It also
checks context-reset mutants, Google-formatted Java companions and independent
Kotlin parsing/layout/compact syntax parity.

Public Kotlin constructor-contract properties use the checked strategies and
share one Symbol context across witnesses, input generation, definitions, adapter
bridges and structural assertions. A context is allocated once per sampled case
and remains stable when the framework reads its shrink tree. Required conjunctive
Symbol equalities can draw fixture/prior-input values; disjunctions preserve both
alternatives and retain their predicate check.


The internal `LawSpecKotlinStrategies.checkedGenerator` validates supplied witnesses
and indexes their typed nested values. Native Kotest list/product/choice trees
remain the source of candidates and shrinks. A bounded sampling wrapper retries
false predicates up to `maxAttempts` at each value boundary; Kotest's `RTree.filter`
removes invalid shrink nodes. This avoids Kotest 5.9's unbounded arbitrary-filter
sampling without changing global framework settings. Evaluator errors are retained
as checked errors, including errors discovered during shrinking. Sampled witness
branches can limit payload shrinking; a globally minimal result is not promised.

`tools/kotlin-checked-strategies.mjs` checks both profiles, bounded exhaustion,
valid shrinking, nested witnesses, error classification and Symbol identity, with
compiled behavioral mutants. The legacy unchecked generator rejects schemas with
constructor contracts rather than bypassing their checks.


Generated dependent-input chains retain evaluator errors as case state, skip
subsequent draws after an error, and report the original failure before reading
input bindings. Input filtering accepts failed cases for reporting instead of
silently discarding them. Core-proven finite domains still emit exhaustive cases.
`tools/kotlin-field-properties.mjs` runs public generation at both widths and
layouts, with custom placement, finite domains, typed native adapters, nested
presence and lists, disjunctive fixtures, evaluator errors and incorrect adapters.
