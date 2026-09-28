# Native Go data

LawSpec 0.9 generates native named Go types for parameterized products and sums.
The compiler consumes checked Core declarations, plans names across all units,
and emits sealed interfaces plus named variant structs, following Go+'s enum
lowering approach.

For example:

```lawspec
unit example.trees

type Tree (a :: Type) is
  Leaf value :: a
  Branch children :: List (Tree a)
end

echo :: Tree Int8 -> Tree Int8

law `echo preserves the tree` is
  definition is `for all` (x :: Tree Int8) . echo x = x end
end
```

The adapter receives `Tree[int8]`. Its native variants are `TreeLeaf[int8]`,
with an exported `Value` field, and `TreeBranch[int8]`, with an exported
`Children []Tree[int8]` field. The interface's private marker method includes
the type parameters, so even a nullary or phantom variant retains its generic
identity. Go rejects a `TreeLeaf[bool]` where `Tree[int8]` is required.

A correct identity adapter is:

```go
func Echo(value0 Tree[int8]) Tree[int8] {
	return value0
}
```

Adapters remain user-owned. Generated files belong to the same unit package;
custom Go layouts keep source and tests in a shared directory tree. Duplicate
type names across units receive qualified generated names. The compiler rejects
adapter names that collide with generated native declarations or runtime names.

## Containers and presence

- `List a` uses `[]T`. Nil and empty slices represent the same empty list.
- `Maybe a` uses `LawSpecMaybe[T]`, constructed with `LawSpecNothing[T]()` or
  `LawSpecJust(value)`. `Value()` returns the payload and its presence flag.
- `Either a b` uses `LawSpecEither[L, R]`, constructed with
  `LawSpecLeft[L, R](value)` or `LawSpecRight[L, R](value)`. Its zero value is
  invalid and checked conversion rejects it.
- `Nullable a` and `Optional a` use distinct generic support structs with
  `Present` and `Value` fields. These tags preserve nested absence states.

Native scalar fields retain their domains: UInt64 uses `uint64`, arbitrary
integers use `*LawSpecBigInt`, rational values use `*LawSpecRational`, and raw
UTF-16 text uses `[]uint16`. Text uses a valid UTF-8 Go string; arbitrary bytes
use `[]byte`. Unit, Null, and Undefined have distinct named support types when
stored inside data. Native void adapter results continue to normalize to Unit.

## Total definitions

Checked source definitions emit native methods on `LawSpecDefinitions` in the
unit's package:

```lawspec
unit example.total

definition increment (x :: Int8) :: BigInt is x + 1 end
```

```go
symbols := map[string]*LawSpecSymbol{}
result := LawSpecDefinitions.Increment(symbols, 127) // big integer 128
```

The method accepts `int8` and returns `*LawSpecBigInt`. Lists, products, sums, and
nested presence retain their native parameterized types. A dedicated method
namespace allows a definition named `architecture` to coexist with the native
`Architecture` data type. Ordinary adapter functions retain their existing names.

Reuse the Symbol context within one example. Checked codecs copy and validate
native arguments and results; failures panic with the resolved definition name.
Machine-sized native bindings check the architecture across the complete type,
including alternatives not selected by the current value. Logical evaluation
still follows the explicitly selected machine profile.

`lawspec_definitions.go` belongs in source directories and does not import Rapid.
It contains the unit's native entry points and checked logical bodies. Properties
call the bodies directly; definitions never become user-owned adapter stubs.
Definitions and properties share typed expression rendering, preserving lazy
branches, short-circuit guards, single evaluation of match inputs, exact
arithmetic, and structural equality.

The frontend checks structural termination and potentially failing operations.
Generic definitions specialize to concrete uses. Refined signatures become
checked contracts, and refinement predicates may call checked definitions.

`tools/go-definitions-integration.mjs` checks source-only packages, four rejected
native type mismatches, both profiles and architecture diagnostics, recursive
properties, incorrect adapters, custom layouts, compact execution, and
regeneration protection. Readable definition source matches `gofmt` exactly.
Compact Go documents retain tabs rather than expanding them into spaces.

## Checked bridges and tests

Generated codecs validate both conversion directions and copy mutable payloads.
An adapter cannot mutate a list, byte slice, or big integer in a test fixture
through an input alias. Unexpected or nil native variants, invalid scalar
representations, and cyclic values fail with type/field context. Shared acyclic
subtrees remain valid. Native machine-sized fields require the selected
`machineBits` profile to match the Go architecture.

Generated equality follows LawSpec semantics, including componentwise floating
comparison and Symbol identity. It does not substitute Go pointer identity or
reflection-based equality for structural equality.

Rapid generation composes native generators and shrinkers. A structural node
budget bounds recursive values, reserves each product field's minimum cost,
and permits list lengths supported by the remaining budget. Empty domains,
nullary constructors, and nested absence states are handled explicitly.

The reusable source files (`lawspec_runtime.go`, `lawspec_schema.go`,
`lawspec_codecs.go`, and generated data/schema/codec declarations) do not import
Rapid. Framework-specific generation lives in
`lawspec_data_strategies_test.go`; generated laws live in `lawspec_test.go`.

Native declarations, schema descriptions, codecs, runtime support, and generated
tests use structured formatting that matches `gofmt`. The bundled examples and
total-definition fixture are checked against `gofmt` under both machine profiles.
No external formatter is needed when generating code.

The compiler and CLI accept explicit `--minify` for generated output.
Readable output remains the default; formatting changes preserve adapter ownership
and edited-file protection. The bundled WASM uses the same layout.

Internal typed Core definitions with attached contracts are proved before Go
emission. Generated logical entry points validate arguments, check preconditions
in order, validate the result, and check postconditions; native wrappers share
these checks. The standalone contract fixture exercises both machine profiles
and formatting modes, including exact division, checked narrowing, nested calls,
and rejection of deliberately corrupted results. Readable contract bodies match
`gofmt`. Refined source definition signatures now produce these contracts through
template proof and specialization.
