# Native Haskell data

LawSpec 0.9 emits ordinary parameterized algebraic data types from checked Core
products and sums. Constructors and record selectors have stable names planned
across all units. For example:

```lawspec
unit example.trees

type Tree (a :: Type) is
  Leaf value :: a
  Branch children :: List (Tree a)
end

echo :: Tree Int8 -> Tree Int8
```

The generated `LawSpecData` module supplies `Tree a`, `TreeLeaf`, and
`TreeBranch`. An adapter can implement identity directly:

```haskell
echo :: Data.Tree I.Int8 -> Data.Tree I.Int8
echo value = value
```

The generated adapter imports `LawSpecData` as `Data` and `Data.Int` as `I`.
Adapters remain user-owned. Recursive and mutually recursive fields use native
Haskell recursion; phantom parameters remain in signatures. Empty data types
have no constructors. They can appear in inhabited containers such as
`Maybe Empty`, but cannot supply a standalone generated argument.

## Containers and scalar representations

| LawSpec | Haskell |
| --- | --- |
| `List a` | `[a]` |
| `Text` | `Data.Text.Text` |
| `List Char` | `[Char]`, the linked-list representation |
| `Maybe a` | `Maybe a`, with `Nothing` and `Just` |
| `Either a b` | `Either a b`, with `Left` and `Right` |
| `Nullable a` | `LS.Nullable a`, with `NullValue` and `NullableValue` |
| `Optional a` | `LS.Optional a`, with `UndefinedValue` and `OptionalValue` |
| `BigInt`, `BigUInt`, `Integer` | `Integer`, with domain checks |
| `Integer` adapter result | `LS.IntegerValue`, built from any `Integral` with `LS.integerValue` |
| `Decimal` | `LS.Decimal`, wrapping an exact finite base-ten `Rational` |
| `Rational` | `Rational` |
| `Complex64`, `Complex128` | `Complex Float`, `Complex Double` |
| `CodePoint` | `Char`, including surrogate code points |
| `CodeUnit16` | `Word16` |
| `CodePointText`, `Utf16Text` | `LS.CodePointText [Char]`, `LS.Utf16Text [Word16]` |
| `Bytes` | `ByteString` |
| `Symbol` | `LS.Symbol`, with scoped fixture identities |
| `Unit` | `()` |
| `Null`, `Undefined` | `LS.Null`, `LS.Undefined` |

`Char` and `Text` exclude surrogate code points. Checked codecs reject invalid
native values rather than replacing characters. `Symbol` equality uses its
identity; matching descriptions alone do not establish equality. Distinct
presence wrappers preserve nested absence states. IEEE NaN and signed-zero
equality remain the same inside containers and custom types.

## Generated support and testing

`LawSpecData`, `LawSpecDataSchema`, `LawSpecDataCodecs`, `LawSpecSchema`,
`LawSpecCodecs`, and `LawSpecRuntime` belong in the source directory. They have no
property-framework dependency. Native conversion returns contextual failures for
invalid domains, fields, tags, or arities. Binding machine-sized native types
requires the selected `machineBits` profile to match the host, including fields
of unselected variants.

`LawSpecDataStrategies` belongs in the test directory and composes native Hedgehog
generators and shrinkers. Bounded recursive generation reserves every product
field's minimum size before distributing spare nodes. Lists have variable lengths
within the available budget. Shrinking uses Hedgehog's choices, integers, and
lists, retaining schema-valid representations.

The Haskell scaffold uses Hspec, Hedgehog, hspec-hedgehog, containers, and mtl in
its test component. Source and test roots can be customized independently.
Readable/compact declaration fixtures are covered by
`tools/haskell-data-integration.mjs`; main compiler output and incorrect adapters
are covered by `tools/haskell-data-properties.mjs`.

## Formatting

Haskell output uses an 80-column layout with spaces for indentation. Runtime
sources, native declarations, adapter stubs, definitions, and property files are
readable by default. Explicit `--minify` selects compact documents while retaining
the layout required by Haskell. Generation uses the same deterministic document
renderer in native and WASM builds; it does not invoke a downloaded formatter.

`tools/haskell-formatting-integration.mjs` checks the bundled corpus at both
machine widths for line length, tabs, and trailing whitespace. It compares
readable and compact parsed syntax using `tools/HaskellSyntaxCheck.hs`, built
against the installed GHC parser. The comparison discards source locations and
layout annotations while retaining literals, operators, and program structure.
Set `LAWSPEC_CORE`, `LAWSPEC_GHC`, and `LAWSPEC_HASKELL_SYNTAX_CHECK` to the
corresponding executables. This is a development check, not a package dependency.

## Total definitions

Checked definitions become native functions in `LawSpecDefinitions.<Unit>`:

```lawspec
unit example.total

definition increment (x :: Int8) :: BigInt is x + 1 end
```

The generated native signature is equivalent to:

```haskell
increment :: LS.SymbolContext -> I.Int8 -> Either String Integer
```

Create a context with `LS.newSymbolContext`, then pass it to calls belonging to
the same example. A repeated Symbol fixture ID has the same identity in that
context; separate contexts remain distinct even when IDs and descriptions match.
Codecs preserve the identity of already-scoped native Symbols. Creating the
context uses IO; evaluating a definition is pure.

Native entry points check arguments and results and return contextual `Left`
diagnostics for invalid native representations. Native machine-sized bindings
check the whole type, including unselected constructors, against `machineBits`.
`LawSpecDefinitionBodies` contains the shared logical implementation, which uses
the configured machine profile independently of the host architecture.

Definitions do not create adapter stubs. Their source modules and scalar/schema
support have no Hspec or Hedgehog dependency. Generated tests allocate a context
per example, boundary, or property iteration. Properties and definitions share a
typed expression renderer with lazy guards, exhaustive matching, structural
equality, checked conversions, and exact integer promotion.

`tools/haskell-definitions-integration.mjs` exercises native and property calls,
both machine profiles, readable/compact definitions, complete minified projects,
custom source/test roots,
native type errors, incorrect adapters, generic specialization, and regeneration
protection. Refined definition signatures are checked before emission and
enforced at native entry points.


Hspec property files now use structured documents for helpers, examples,
boundaries/finite cases, native Hedgehog strategies, dependent refinement domains,
guarded assertions and contract wrappers. Adapter bridges compose checked codecs
and force argument values before calling native code. Contracts retain lazy
precondition checks and force the result before checking postconditions. Fresh
Symbol contexts cover refined properties as well as ordinary native strategies.
Scalar literals and diagnostic strings now use document-level encoding. Long
strings concatenate independently escaped chunks; large integers parse exact
decimal strings with their required Integer type.

`tools/haskell-data-properties.mjs` accepts `LAWSPEC_MINIFY=1` and
`LAWSPEC_MACHINE_BITS=32,64`. Its scalar scenario includes bundled examples and
shared arithmetic conformance vectors; its refinements scenario includes four
faulty adapters. Native machine-sized adapter bindings require a matching host
architecture; the scalar scenario defaults to 64 bits.

`tools/haskell-message-integration.mjs` uses native code-point strings and integer
constants independent of the emitter to check Unicode, escapes, whitespace,
large signed integers and diagnostic prefixes in readable and compact modes.
Its executable fixture lines fit within 80 columns. Long metadata comments wrap
to the output width.

Internal typed Core definitions with attached contracts are proved before Haskell
emission. Generated source checks preconditions after argument validation and
postconditions after result validation, without property-framework dependencies.
Checks sequence through Either, so a rejected precondition prevents later
predicates and the body from running. Results are forced and validated before
postconditions. Readable contract fixtures fit within 80 columns.
The shared native fixture passes both machine profiles and formatting modes,
including exact division, narrowing, nested calls, direct logical entry checks,
and rejection of corrupted results. Refined source definition signatures now
produce these contracts through template proof and specialization.
