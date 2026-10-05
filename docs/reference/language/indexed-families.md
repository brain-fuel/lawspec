# Indexed families

A data type can be indexed by natural numbers, such as a vector indexed by its
length or a tree indexed by its size. Each constructor states how it determines
the index.

## Declaring a family

```lawspec
unit guide.indexed

type Vec (n :: Natural) (a :: Type) is
  | VNil where n = 0
  | VCons head :: a tail :: Vec m a where n = m + 1
end

append :: (xs :: Vec n Int8) -> (ys :: Vec m Int8) -> (r :: Vec (n + m) Int8)

definition concatV (xs :: Vec n Int8) (ys :: Vec m Int8) :: Vec (n + m) Int8 is
  match xs with
  | VNil -> ys
  | VCons h t -> VCons h (concatV t ys)
  end
end

law `append agrees with the proved definition` is
  definition is
    `for all` (xs :: Vec n Int8) (ys :: Vec m Int8) . append xs ys = concatV xs ys
  end
end
```

A multi-field constructor can split its index:

```lawspec fragment
type Tree (n :: Natural) (a :: Type) is
  | Tip where n = 0
  | Bin left :: Tree l a value :: a right :: Tree r a where n = l + r + 1
end
```

Rules:

- Index expressions use natural arithmetic: literals, index variables, `+`,
  `-`, `*`, `div`, `mod` and `^`. `^` binds tightest and needs a literal base
  or a literal exponent.
- A variable such as `m` is bound by the field whose type mentions it.
- Every index has exactly one equation in every constructor.
- `Natural` is also an ordinary value type: an unbounded integer that is at
  least zero.

## Arithmetic, subtraction and shared indices

```lawspec
unit guide.arithmetic

type Row (n :: Natural) is
  | End where n = 0
  | Cell head :: Int8 tail :: Row m where n = m + 1
end

-- Both subtrees share one height: a perfect tree.
type Perfect (n :: Natural) is
  | Leaf value :: Int8 where n = 0
  | Node left :: Perfect m right :: Perfect m where n = m + 1
end

-- A grid's index is its number of cells.
type Grid (n :: Natural) is
  | Grid rows :: Row r columns :: Row c where n = r * c
end

type Rest (n :: Natural) is
  | Rest items :: Row m where n = m - 1
end

dropFirst :: (xs :: Row (k + 1)) -> (r :: Rest k)
```

- **Shared indices.** A variable bound by several fields makes their indices
  equal. `Node` holds two trees of one height; this is checked at
  construction and decode, and generation builds both from the same index.
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

Generation follows the index:

- A free index, as in `append`, takes values from the erased type; the index is
  their measure.
- A fixed index (`Vec 3 Int8`) or a shared one (`zip`'s second argument in
  `zip :: (xs :: Vec n Int8) -> (ys :: Vec n Bool) -> (r :: Vec n Bool)`) is
  solved backwards through the constructor equations. `VCons` for `n = 3` needs
  a tail with index 2; `Bin` splits `n - 1` between its subtrees.
- Every runtime first finds the indices each constructor can reach, up to the
  target plus 16, and then solves the target backwards through any equation:
  `Grid 12` draws its rows and columns among the divisors of twelve. A family
  with shared indices or guards is built from a few small indices even when no
  index is fixed, since random values would almost never satisfy them.

Values are constructed, not filtered, and shrinking stays within the index on
every target. The same planning applies to any measure you write over declared
data whose branches are a constant plus the same measure of the branch's
fields.

## Proved indices

A checked definition can return an indexed family. The compiler proves its
result index statically, as for `concatV` above, so the generated code has no
runtime postcondition for it.

The proof uses exact linear arithmetic over the measures:

- A measure applied to a known constructor unfolds to that constructor's
  equation: `nOfVec (VCons h t)` is `nOfVec t + 1`.
- Inside a match branch, the scrutinee's constructor is known.
- Calls of checked definitions are pure, so equal calls have equal results.
- A recursive call contributes its own signature as the induction hypothesis.
- Natural measures are non-negative.

A definition whose result index does not follow is rejected with
`definition result refinement could not be proved`.

A match may leave out a constructor that the value's index rules out. A
`Vec (n + 1) a` is never `VNil`, so taking its head needs one branch:

```lawspec fragment
definition headV (xs :: Vec (n + 1) Int8) :: Int8 is
  match xs with
  | VCons h t -> h
  end
end
```

The compiler proves each left-out constructor impossible. A constructor the
index allows is an error that names it: `a match leaves out VNil, which its
value's index allows`.

A proved definition makes a natural reference model for a native adapter, as
`concatV` does for `append`. The [indexed example](../../../examples/specs/indexed_families.lawspec)
also proves `flattenV` for trees.
