---
id: lawspec.how-to.targets.haskell
kind: how-to
title: Set up Haskell
---
# Set up Haskell

## Requirements

- Stack with the `lts-24.58` snapshot (GHC 9.10).
- Test dependencies: hspec 2.11, hedgehog 1.5, hspec-hedgehog 0.3 and
  hspec-discover.
- `text` and `bytestring` as direct dependencies of the component that compiles
  the generated source.

## Create the project

```sh
npx lawspec init --target haskell
stack build --test --no-run-tests
npx lawspec doctor
npx lawspec generate
stack test
```

In a directory without build files, `init` creates:

- `stack.yaml` with `snapshot: lts-24.58`;
- `package.yaml` with a library in `src` depending on `base`, `text` and
  `bytestring`, and a `laws` test suite in `test` depending on hspec, hedgehog,
  hspec-hedgehog, containers and mtl, with the `hspec-discover` build tool;
- `test/Spec.hs`, which runs hspec-discover.

The generated test component uses `-O0` to keep deeply composed Hedgehog
generators practical to compile. Adapters and checked-definition libraries use
the project's optimization settings. See [GHC's optimization controls](https://downloads.haskell.org/ghc/9.10.3/docs/users_guide/using-optimisation.html).

Run `stack build --test --no-run-tests` once before `doctor`. It resolves the
snapshot and generates the Cabal file through Hpack. `doctor` reads that file
and never rewrites it. The target root must contain exactly one Cabal package.

## Layout

| Files | Directory |
| --- | --- |
| Adapters (yours), one module per unit, such as `Example.Trees` | `src` |
| `LawSpecData`, `LawSpecDataSchema`, `LawSpecDataCodecs`, `LawSpecSchema`, `LawSpecCodecs`, `LawSpecRuntime` | `src` |
| `LawSpecDefinitions.<Unit>`, `LawSpecDefinitionBodies` | `src` |
| Specs, such as `Example/TreesSpec.hs`, and `LawSpecDataStrategies` | `test` |

Source modules have no Hspec or Hedgehog dependency. Source and test roots can
be changed independently.

## Native representations

Products and sums become ordinary parameterized algebraic data types in
`LawSpecData`. For:

```lawspec fragment
type Tree (a :: Type) is one of
  Leaf  of type a
  Branch  of type List (Tree a)
end type

echo :: Tree Int8 -> Tree Int8
```

the adapter is:

```haskell
echo :: Data.Tree I.Int8 -> Data.Tree I.Int8
echo value = value
```

The adapter module imports `LawSpecData` as `Data` and `Data.Int` as `I`. The
constructors are `TreeLeaf` and `TreeBranch`. A product's constructor has the
type's name: `type Pair is Pair first :: Int8 second :: Int8 end` becomes
`data Pair = Pair ...`. Empty types have no constructors:
they can appear in inhabited containers such as `Maybe Empty`, but cannot be
generated on their own.

| LawSpec | Haskell |
| --- | --- |
| `List a` | `[a]` |
| `Text` | `Data.Text.Text` |
| `List Char` | `[Char]` |
| `Maybe a`, `Either a b` | `Maybe a`, `Either a b` |
| `Nullable a` | `LS.Nullable a`, with `NullValue` and `NullableValue` |
| `Optional a` | `LS.Optional a`, with `UndefinedValue` and `OptionalValue` |
| `Whole`, `Nat`, `Integer` argument | `Integer`, with domain checks |
| `Integer` result | `LS.IntegerValue`, built from any `Integral` with `LS.integerValue` |
| `Decimal` | `LS.Decimal`, an exact finite base-ten `Rational` |
| `Duration` | The generated `Duration` record, holding an `Integer` of microseconds |
| `Rational` | `Rational` |
| `Complex64`, `Complex128` | `Complex Float`, `Complex Double` |
| `CodePoint`, `CodeUnit16` | `Char` (including surrogates), `Word16` |
| `CodePointText`, `Utf16Text` | `LS.CodePointText [Char]`, `LS.Utf16Text [Word16]` |
| `Bytes` | `ByteString` |
| `Symbol` | `LS.Symbol`, with scoped fixture identities |
| `Unit`, `Null`, `Undefined` | `()`, `LS.Null`, `LS.Undefined` |

`Text` and `List Char` are different LawSpec types, even when they hold the same
characters. For an abstract `Integer` result:

```haskell
successor :: Int8 -> IntegerValue
successor x = integerValue (toInteger x + 1)
```

Machine-sized types bind native machine-sized integers. Their codecs check the
host against `machineBits` for the whole type, including unselected
constructors.

## Checked definitions

```lawspec
unit example.total

function increment (x :: Int8) -> Integer is x + 1 end function
end unit
```

produces, in `LawSpecDefinitions.Example.Total` (following the unit name), a
function equivalent to:

```haskell
increment :: LS.SymbolContext -> I.Int8 -> Either String Integer
```

Create a context with `LS.newSymbolContext` (in `IO`) and pass it to every call
in one example. Evaluation itself is pure. Invalid native values give a `Left`
with context.

## Generation and shrinking

Tests use Hspec with Hedgehog generators and shrinkers. Hedgehog receives
`cases` as its test limit, `maxAttempts` as its discard limit and `maxShrinks`
as its shrink limit.

## Formatting

Output is what `ormolu` writes: LawSpec lays it out itself, so generation
needs no formatter, and LawSpec's own acceptance checks every generated
project with `ormolu --mode check` (ormolu 0.9.0.0). Lines are kept near 80
columns, which ormolu leaves as they are; expressions are printed by
precedence, so an argument is parenthesised only when it is not an atom.
`--minify` allows a compact layout. See
[formatting](../../reference/formatting.md).

## Names

Generated code uses the specification's names. Binders keep their source
names; a checked definition is a function named after it
(`Definitions.feeModel`, `Typed.feeModel`), with `_2` only when two would
share a name; typed conversions are named after their type (`toPayment`,
`fromNativeListInt32`). A test is named after its law and example:
`lawNormalizersAgree_spacesBecomeHyphensPunctuationIsPreserved`, and
`_boundary1`, `_property`. An anonymous record is a data type named from
where it is used: the payload of a `Push` case is `PushDetails`. Each test,
definition and handler has a comment linking it to its source line, and text
is written as Haskell string literals (`LS.textScalar "café"`).

What every test shares is in the runtime: `LawSpecTesting.assertEqual`, the
seeded Hedgehog check (`holds`), `LawSpecSchema.checked` and its kin, and
`LawSpecCodecs.call1` to `call8`, which call an adapter with checked,
evaluated arguments. A test module names its machine width (`machineBits`),
schema and scalar codecs once, and imports only what it uses.
