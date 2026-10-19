---
id: lawspec.reference.language.indexed-families
kind: reference
title: Indexed families
---
# Indexed families

A data type can be indexed by non-negative whole numbers, such as a vector
indexed by its length or a tree indexed by its size. Each constructor states how it determines
the index.

## Declaring a family

```lawspec
unit guide.indexed

type Vec (n :: Whole) (a :: Type) is one of
  | VNil where n = 0
  | VCons of type record{ head :: a tail :: Vec m a} where n = m + 1
end type

append :: (xs :: Vec n Int8) -> (ys :: Vec m Int8) -> (r :: Vec (n + m) Int8)

function concatV (xs :: Vec n Int8) (ys :: Vec m Int8) -> Vec (n + m) Int8 is
  first matching case of xs :
    when VNil then ys
    when VCons record{ head = h , tail = t} then VCons record{ head = h , tail =
        (concatV t ys)}
  end case
end function

law "|append agrees with the proved definition| is
  definition :
    for all (xs :: Vec n Int8) (ys :: Vec m Int8) => append xs ys = concatV xs
      ys end for all
  end definition
end law

end unit
```

A multi-field constructor can split its index:

```lawspec fragment
type Tree (n :: Whole) (a :: Type) is one of
  | Tip where n = 0
  | Bin of type record{ left :: Tree l a value :: a right :: Tree r a} where n =
  l + r + 1
end type
```

Rules:

- Index expressions use non-negative integer arithmetic: literals, index variables, `+`,
  `-`, `*`, `div`, `mod` and `^`. `^` binds tightest and needs a literal base
  or a literal exponent.
- A variable such as `m` is bound by the field whose type mentions it.
- Every index has exactly one equation in every constructor.
- `Whole` is also an ordinary value type: an unbounded integer including zero.
  `Nat` starts at one. Use `Whole` for zero-inclusive indices.

## Arithmetic, subtraction and shared indices

```lawspec
unit guide.arithmetic

type Row (n :: Whole) is one of
  | End where n = 0
  | Cell of type record{ head :: Int8 tail :: Row m} where n = m + 1
end type

-- Both subtrees share one height: a perfect tree.
type Perfect (n :: Whole) is one of
  | Leaf  of type Int8 where n = 0
  | Node of type record{ left :: Perfect m right :: Perfect m} where n = m + 1
end type

-- A grid's index is its number of cells.
type Grid (n :: Whole) is one of
  | Grid of type record{ rows :: Row r columns :: Row c} where n = r * c
end type

type Rest (n :: Whole) is one of
  | Rest  of type Row m where n = m - 1
end type

dropFirst :: (xs :: Row (k + 1)) -> (r :: Rest k)

end unit
```

- **Shared indices.** A variable bound by several fields makes their indices
  equal. `Node` holds two trees of one height; this is checked at
  construction and decode, and generated values must satisfy that constraint.
- **Subtraction never truncates.** `n = m - 1` requires `m >= 1` of every
  value, as a constructor constraint (`RUNTIME CHECKED`).
- **Inverted patterns.** An implicit index may first appear as `v`, `v + k` or
  `k * v`. `dropFirst` binds `k` to one less than its argument's length, and
  requires the length to be at least one.
- **Non-linear claims.** A definition's result index that needs non-linear
  arithmetic, such as `(r + r) * c = 2 * (r * c)`, is beyond the prover. It is
  checked on each result instead and reported as `RUNTIME CHECKED`. A purely
  linear claim that does not follow is still an error.

## What a family means

Indices are evidence, not a second type system. Before type inference, the
compiler turns a family into three ordinary declarations:

- erased data `Vec a` with the same constructors, which is the native
  representation on every target;
- a checked measure for each index, named `<index>Of<Type>` (here `nOfVec`),
  which recomputes the index from a value using the constructor equations;
- a refinement, so that `Vec e a` in any signature or quantifier means
  `(v :: Vec a where nOfVec v == e)`.

`append` above is therefore an adapter contract: its result must have length
`nOfVec xs + nOfVec ys`. A native implementation that drops an element fails
the postcondition.

## Implicit indices

An index variable that is not otherwise bound, like `n` and `m` in `append`, is
implicit. The first binder whose type mentions it alone determines it; later
occurrences read that binder's measure. An implicit index cannot first appear
inside an expression, and a result cannot introduce one.

## Generation

Generation preserves the index constraints. Direct constructive planning
currently handles supported single-payload family paths, such as a counting
family with a payload-free zero and a successor carrying another count.
It does not solve through an intervening record payload.
Consequently, the record-based `Vec`, `Tree`, `Perfect` and `Grid` declarations
above use ordinary checked generation unless a harness supplies construction
strategies. Checked generation filters candidates and rechecks shrinks against
the predicates and constructor guards. A bounded failure to find a candidate
does not prove that the type is empty.

For supported direct paths, the planner works as follows:

- A free index, as in `append`, takes values from the erased type; the index is
  their measure.
- A fixed or shared index is solved backwards through supported constructor
  equations.
- The planner first finds the indices each constructor can reach, up to the
  target plus 16, and then solves the supported equations backwards. A family
  with shared indices or guards is built from a few small indices even when no
  index is fixed, since random values would almost never satisfy them.

The [indexed examples](../../../examples/specs/indexed_families.lawspec) use
explicit harness strategies for sparse record-based domains. They construct
vectors of the required length and trees of the required size while retaining
independent generation of their values. This exercises the laws without
claiming that the direct planner supports nested record paths.

## Proved indices

A checked definition can return an indexed family. The compiler proves its
result index statically, as for `concatV` above, so the generated code has no
runtime postcondition for it.

The proof uses exact linear arithmetic over the measures:

- A measure applied to a known constructor unfolds to that constructor's
  equation: `nOfVec (VCons record{head = h, tail = t})` is `nOfVec t + 1`.
- Inside a match branch, the scrutinee's constructor is known.
- Calls of checked definitions are pure, so equal calls have equal results.
- A recursive call contributes its own signature as the induction hypothesis.
- Measures are non-negative.

A definition whose result index does not follow is rejected with
`definition result refinement could not be proved`.

A match may leave out a constructor that the value's index rules out. A
`Vec (n + 1) a` is never `VNil`, so taking its head needs one branch:

```lawspec fragment
function headV (xs :: Vec (n + 1) Int8) -> Int8 is
  first matching case of xs:
    when VCons record{head = value} then value
  end case
end function
```

The compiler proves each left-out constructor impossible. A constructor the
index allows is an error that names it: `a match leaves out VNil, which its
value's index allows`.

A proved definition makes a natural reference model for a native adapter, as
`concatV` does for `append`. The [indexed example](../../../examples/specs/indexed_families.lawspec)
also proves `flattenV` for trees.
