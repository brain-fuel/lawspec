# Set up Go

## Requirements

- Go 1.22 or later (1.22–1.26 are supported), with Go modules.
- Rapid v1.2.0, without a local `replace`.

## Create the project

```sh
npx lawspec init --target go
npx lawspec doctor
npx lawspec generate
go test ./...
```

In a directory without build files, `init` creates a `go.mod` for module
`example.com/lawspec-example` with `go 1.22` and Rapid v1.2.0. In an existing
module:

```sh
go get pgregory.net/rapid@v1.2.0
go mod download
```

## Layout

Each unit becomes a Go package in a directory named after the unit, at the
project root (`example/trees` for unit `example.trees`). Adapters, generated
source and tests share that directory: Go tests live in the package they test,
so `sourceDir` and `testDir` must be equal if you set them.

| Files | Contents |
| --- | --- |
| `adapter.go` (yours) | The unit's adapter functions |
| `lawspec_runtime.go`, `lawspec_schema.go`, `lawspec_codecs.go`, data declarations | Runtime, types and checked codecs; no Rapid import |
| `lawspec_definitions.go` | Checked definitions |
| `lawspec_test.go`, `lawspec_data_strategies_test.go` | Tests and Rapid generators |

Adapter names that collide with generated declarations or runtime names are
rejected. When two units declare the same type name, the generated names are
qualified by unit.

## Native representations

A product, a type with one constructor, is a plain generic struct named after
the type, with exported fields. A sum becomes a sealed interface with named
generic variant structs. For:

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

the adapter receives `Tree[int8]`, whose variants are `TreeLeaf[int8]` (field
`Value`) and `TreeBranch[int8]` (field `Children []Tree[int8]`). The
interface's marker method includes the type parameters, so Go rejects a
`TreeLeaf[bool]` where a `Tree[int8]` is required. Switch on the variants:

```go
func Size(value0 Tree[int8]) int {
	switch tree := value0.(type) {
	case TreeLeaf[int8]:
		return 1
	case TreeBranch[int8]:
		total := 0
		for _, child := range tree.Children {
			total += Size(child)
		}
		return total
	}
	panic("unknown Tree variant")
}
```

`type Pair is Pair first :: Int8 second :: Int8 end` becomes
`type Pair struct { First int8; Second int8 }`, read as `value0.First`.

```go
func Echo(value0 Tree[int8]) Tree[int8] {
	return value0
}
```

| LawSpec | Go |
| --- | --- |
| Fixed-width integers | `int8`…`int64`, `uint8`…`uint64` |
| `IntSize`, `UIntSize`, `UIntPtr` | Native machine-sized integers, checked against `machineBits` |
| `BigInt`, `BigUInt`, `Rational` | `*LawSpecBigInt`, `*LawSpecRational` (aliases of `math/big` types) |
| `Integer` result | Any signed or unsigned integer, or a `big.Int` value or pointer, through `any` |
| Floats and complex values | `float32`, `float64`, `complex64`, `complex128` |
| `Duration` | `time.Duration` of whole microseconds (`LawSpecDuration` in generated code) |
| `Text` | A valid UTF-8 `string` |
| `Bytes`, `Utf16Text` | `[]byte`, `[]uint16` |
| `List a` | `[]T`; `nil` and empty slices are the same list |
| `Maybe a` | `LawSpecMaybe[T]`, built with `LawSpecNothing[T]()` or `LawSpecJust(value)`; `Value()` returns the payload and a presence flag |
| `Either a b` | `LawSpecEither[L, R]`, built with `LawSpecLeft[L, R](value)` or `LawSpecRight[L, R](value)`; the zero value is invalid |
| `Nullable a`, `Optional a` | Distinct generic structs with `Present` and `Value` fields |
| Other domains | `LawSpecValue` |

`Unit`, `Null` and `Undefined` have distinct named types when stored inside
data. An adapter returning `Unit` may return nothing.

Generated codecs validate both directions and copy mutable payloads, so an
adapter cannot change a test's list, byte slice or big integer through an
alias. Nil or unknown variants, invalid scalars and cyclic values fail with
context. LawSpec equality is generated; it does not use pointer identity or
reflection.

## Checked definitions

Definitions become methods on `LawSpecDefinitions` in the unit's package:

```lawspec
unit example.total

definition increment (x :: Int8) :: BigInt is x + 1 end
```

```go
symbols := map[string]*LawSpecSymbol{}
result := LawSpecDefinitions.Increment(symbols, 127) // big integer 128
```

The method takes `int8` and returns `*LawSpecBigInt`. Reuse one Symbol map
within an example. Invalid arguments or results panic with the definition's
name. The separate method namespace lets a definition named `architecture`
coexist with a type named `Architecture`.

## Generation and shrinking

Tests use Rapid generators and Rapid's replay-based shrinking. Structural
properties honour `cases`. Refinement filters use at most the smaller of
`maxAttempts` and Rapid's own five-attempt limit. Minimization of structural
properties follows Rapid's `-rapid.shrinktime` setting rather than
`maxShrinks`.

## Formatting

Output matches `gofmt`. No formatter is run during generation.
