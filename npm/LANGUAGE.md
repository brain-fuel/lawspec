# LawSpec language and compiler boundary (0.12)

LawSpec describes portable laws, concrete examples, and adapter contracts. The
compiler is written in Haskell. Rust is an output backend alongside Java, Python,
JavaScript, TypeScript, Go, Haskell, and Kotlin.

## Lists and algebraic containers

`List a` is an ordered, finite sequence of values of one type. Lists nest and
retain duplicates. Literals use brackets; their element type comes from the
surrounding signature, quantifier, or annotation. An unconstrained empty list
needs an annotation such as `([] :: List Int8)`.

```lawspec
unit guide.lists

reverse :: List Int32 -> List Int32

law `reverse preserves length` is
  definition is
    `for all` (xs :: List Int32) .
      prelude.length (reverse xs) = prelude.length xs
  end
  example `duplicates count separately` is
    xs = [3, 1, 3]
    expect prelude.length xs = 3
    expect reverse xs = [3, 1, 3]
  end
end
```

`prelude.length` returns an exact integer. List equality compares corresponding
values in order and requires equal lengths. It preserves scalar equality rules:
NaN still differs from itself, signed zeros compare equal, and Symbols compare
by identity. Generic list equality requires `Eq a`.

`Maybe a` has constructors `Nothing` and `Just value`. `Either a b` has
constructors `Left value` and `Right value`. These are algebraic sums, separate
from the interoperability types `Nullable a` and `Optional a`.

```lawspec
unit guide.presence

echo :: Maybe (Either Int8 Bool) -> Maybe (Either Int8 Bool)

law `preserve every alternative` is
  definition is `for all` (x :: Maybe (Either Int8 Bool)) . echo x = x end
  example `absent` is x = Nothing expect echo x = Nothing end
  example `left integer` is x = Just (Left 127) expect echo x = Just (Left 127) end
  example `right boolean` is x = Just (Right false) expect echo x = Just (Right false) end
end
```

For `Maybe (Maybe Bool)`, `Nothing`, `Just Nothing`, and `Just (Just false)`
remain distinct. Nesting a constructor application as an argument generally
requires parentheses, as in `Just (Left 127)`.

The [collections example](examples/specs/collections.lawspec) combines reverse
involution, sorting idempotence, sortedness, length, and permutation preservation.
`sorted` and `permutation` in that example are adapters supplied by the user;
they are not built-in helpers. Sortedness and length alone cannot establish that
a sorting adapter retained the original elements.

## Products, sums, and pattern matching

A `type` declaration names its constructors and each constructor's fields. One
constructor describes a product; multiple constructors describe a sum. Type
parameters are declared explicitly with `:: Type`.

```lawspec
unit guide.trees

type Pair (a :: Type) (b :: Type) is
  Pair
    first :: a
    second :: b
end

type Tree (a :: Type) is
  Leaf value :: a
  Branch children :: List (Tree a)
end

definition rebuild (tree :: Tree a) :: Tree a is
  match tree with
    | Leaf value -> Leaf value
    | Branch children -> Branch children
  end
end

law `preserve the constructor and its fields` is
  definition is `for all` (tree :: Tree Int8) . rebuild tree = tree end
  example `nested branches` is
    tree = Branch [Leaf 127, Branch [], Leaf -128]
    expect rebuild tree = Branch [Leaf 127, Branch [], Leaf -128]
  end
end
```

Constructors receive fields in declaration order. A match evaluates its
scrutinee once; each branch binds that constructor's fields in the same order.
Bindings are scoped to the branch. Matching must be exhaustive and cannot repeat
a constructor. Lists match with `Nil` and `Cons head tail`; Maybe and Either use
their constructors above. Recursive declarations must be strictly positive.
Constructors may refine natural indices; see [indexed families](#natural-indexed-families).
GADT result signatures that refine type arguments are not supported.

Equality is structural and type-directed, including named fields and nested
containers. Native public declarations retain their names and type parameters;
schemas and checked codecs support them at runtime. They are not replacements
for the public data types. See the target guides for native representations:
[Java](JAVA.md), [Python](PYTHON.md), [JavaScript/TypeScript](WEB.md),
[Go](GO.md), [Haskell](HASKELL.md), [Kotlin](KOTLIN.md), and [Rust](RUST.md).
In Haskell, `Text` remains `Data.Text.Text`, while `List Char` becomes the linked
list `[Char]`. These are distinct LawSpec types even when they contain the same
characters.

Generators compose the target framework's generators and shrinkers. Recursive
values have a structural size budget; each constructor reserves enough budget
for its fields before distributing the remainder. Boundaries include empty and
singleton lists and constructor-specific values. Small finite domains are
enumerated. An empty type cannot supply a generated argument, but containers
such as `List Empty` and `Maybe Empty` can still be inhabited. An empty or
unreachable input domain never makes a property pass vacuously.

Whole-value refinements can inspect products and sums using exhaustive matches.
List element refinements, Maybe/Either payload refinements, and refined arguments
of recursive and nonrecursive named type constructors are supported; see
[refinements](REFINEMENTS.md#named-data-payloads). Direct refinements on named
constructor fields use checked constructor contracts. Recursive payload predicates
follow stored type arguments and preserve outer dependent inputs.

## Natural-indexed families

A data declaration may take `Natural` parameters. Each constructor states how it
determines them with `where <index> = <expression>`:

```lawspec
type Vec (n :: Natural) (a :: Type) is
  | VNil where n = 0
  | VCons head :: a tail :: Vec m a where n = m + 1
end

type Tree (n :: Natural) (a :: Type) is
  | Tip where n = 0
  | Bin left :: Tree l a value :: a right :: Tree r a where n = l + r + 1
end

append :: (xs :: Vec n Int8) -> (ys :: Vec m Int8) -> (r :: Vec (n + m) Int8)
zip :: (xs :: Vec n Int8) -> (ys :: Vec n Bool) -> (r :: Vec n Bool)
```

Index expressions are sums of natural literals and index variables. A variable
such as `m` is bound by the field whose type mentions it, and every index needs
exactly one equation in every constructor. `Natural` is also an ordinary value
type: an unbounded integer that is at least zero.

Indices are evidence, not a second type system. The compiler elaborates a family
before inference into three ordinary declarations:

- erased data `Vec a` with the same constructors, which is the native
  representation on every target;
- a checked structural measure for each index, named `<index>Of<Type>` (here
  `nOfVec` and `nOfTree`), recomputed from the constructor equations;
- a refinement, so `Vec e a` in any signature or quantifier means
  `(v :: Vec a where nOfVec v == e)`.

`append` above is therefore an adapter contract: its result must have length
`nOfVec xs + nOfVec ys`, and a native implementation that drops an element
fails with the postcondition. An index variable that is otherwise unbound, like
`n` and `m` in `append`, is implicit. It is determined by the first binder whose
family type mentions it alone, and later occurrences read that binder's measure.
Implicit indices must not first appear inside an expression, and a result cannot
introduce one.

Generation follows the index. For a free index, as in `append`, values come from
the erased type and the index is their measure. For a fixed index (`Vec 3 Int8`)
or a shared one (`zip`'s `ys`), the target is solved backwards through the
constructor equations: `VCons` for `n = 3` needs a tail with index 2, and `Bin`
splits `n - 1` between its subtrees. Samples are constructed, not filtered, and
shrinking stays within the index on every target. The same planning applies to
any user-written measure over declared data whose branches are a constant plus
the same measure of that branch's fields.

### Proved indices and evidence

Checked definitions may return indexed families. The compiler proves their
result indices statically, so they need no runtime postcondition:

```lawspec
definition concatV (xs :: Vec n Int8) (ys :: Vec m Int8) :: Vec (n + m) Int8 is
  match xs with
  | VNil -> ys
  | VCons h t -> VCons h (concatV t ys)
  end
end
```

The proof uses exact linear arithmetic over the measures. A measure applied to a
known constructor unfolds to that constructor's equation, so `nOfVec (VCons h t)`
is `nOfVec t + 1`. Within a match branch, the scrutinee's constructor is known.
Calls of checked definitions are pure, so equal calls have equal results. A
recursive call contributes its own signature as the induction hypothesis, and
natural measures are non-negative. A definition whose result index does not
follow fails with `definition result refinement could not be proved`.

Every contract obligation is recorded with how it is discharged. Definition
postconditions are `proved`, and generated code omits their runtime checks.
Definition preconditions guard native callers, and adapter contracts cover
native code that LawSpec cannot inspect, so both are `runtime-checked`.
`lawspec check` summarizes the evidence, and the API reports each obligation in
the `evidence` field. A proved definition is a natural reference model for a
native adapter, as in `append xs ys = concatV xs ys` in the
[indexed example](examples/specs/indexed_families.lawspec).

## Total definitions

A unit can supply an implementation as a checked total definition:

```lawspec
definition increment (x :: Int8) :: BigInt
requires Integer Int8
is
  x + 1
end
```

Parameters and the result have explicit types. The optional `requires` clause
uses the same `Eq`, `Integer`, `Ordered`, and `Bounded` capabilities as laws.
Requirements are checked even when the definition is unused. Bodies must have
exhaustive matches, proven structural descent for recursive calls, and guards
for operations that could otherwise fail. Calls may use other checked
definitions; external adapters cannot establish a definition's totality.

For exact arithmetic, the totality checker can combine linear bounds and Boolean
guards. For example, `x >= 0 && 1 / (x + 1) > 0` is safe for integer `x`: the
right side runs only when its denominator is positive. Proof arithmetic uses
arbitrary exact fractions, preserves strict boundaries, and has a bounded work
budget. An unproved obligation is rejected; IEEE expressions never acquire
rational identities such as `x - x = 0` from this checker.

Primitive integer ranges are available to the checker automatically, including
the selected machine width and BigUInt's nonnegative domain. Integer comparisons
retain integrality: for Int8 `x`, `x < 127 && prelude.Int8 (x + 1) > x` safely
narrows only on the guarded branch. The unguarded conversion is rejected because
`127 + 1` is outside Int8. Range bounds alone do not prove that a Rational or
Decimal input has no fractional part.
Pattern matching retains the primitive ranges of extracted fields within that
branch. For example, an Int8 list head still makes `head + 129` strictly positive;
that fact cannot be reused for an Int64 field in another constructor branch.

Definitions produce reusable generated source with checked native entry points
on all eight targets. They do not produce user-owned adapter stubs. Integer
arithmetic preserves the mathematical result; the example above returns `128`
for the largest Int8 input. See [the total-function example](examples/specs/total_functions.lawspec)
for recursive list counting, structural equality, and explicit expected values.

Definitions can quantify type variables implicitly through their signatures:

```lawspec
definition same (x :: a) (y :: a) :: Bool requires Eq a is x == y end
definition count (xs :: List a) :: BigInt is
  match xs with
    | Nil -> 0
    | Cons head tail -> 1 + count tail
  end
end
```

Each template is checked for typing, capabilities, termination, and definedness,
including unused templates. Calls specialize it to concrete argument and result
types before Core elaboration. Different calls can use different types; recursive
self-calls must retain the same types. Ambiguous calls require an annotation,
such as `count ([] :: List Int8)` to specify an empty list's element type.
Unused templates emit no instances.
Checked definitions may also appear in refinement predicates and adapter
preconditions or postconditions. Their closed call graphs contain only other
checked definitions; adapter calls remain forbidden in predicates. The compiler
uses the same concrete Core definitions to check example domains and plan finite
cases and boundaries that generated tests use at runtime.
Definition parameters and results may carry refinements. The compiler proves
body definedness and result claims under ordered input preconditions, checks
callee preconditions, and preserves the contracts through specialization. Native
entry points enforce the same contracts. See [refined definitions](REFINEMENTS.md#refined-definitions).

## Source and declarations

A source has one named `unit`, function signatures, data declarations, checked
definitions, reusable refinements, and laws. Qualified unit names determine target module/package paths. Function
signatures are curried: `a -> b -> c` takes two inputs and returns `c`. Parentheses
group types and expressions. Comments start with `--` and run to the line end.

The following grammar summarizes the main forms; the parser and executable
compiler tests specify lexical details:

```text
source       = "unit" qualified-name declaration*
declaration  = name "::" type | law | refinement | data-type | function
data-type    = "type" name ("(" name "::" "Type" ")")*
               "is" constructor* "end"
constructor  = name (name "::" type)*
function     = "definition" name parameter* "::" type requirements?
               "is" expression "end"
type         = type-atom ["->" type]
type-atom    = primitive | type-variable | "(" type ")"
             | ("Nullable" | "Optional" | "List" | "Maybe") type-atom
             | "Either" type-atom type-atom
             | data-type-name type-atom*
             | refinement-name argument*
             | "(" name "::" type ["where" expression] ")"
refinement   = "refinement" name parameter* requirements?
               "is" type "end"
parameter    = "(" name "::" type ["where" expression] ")"
requirements = "requires" (capability type)+
capability   = "Eq" | "Integer" | "Ordered" | "Bounded"
law          = "law" quoted-name parameter* requirements? "is"
               "definition" "is" proposition "end"
               description? rationale? example* references? "end"
proposition  = "`for all`" parameter+ "." proposition
             | expression "=" expression
             | expression "implies" proposition
             | proposition "and" proposition
             | quoted-name expression* | expression
expression   = ... | "[" [expression ("," expression)*] "]"
             | constructor-name expression*
             | "match" expression "with"
               ("|" constructor-name name* "->" expression)+ "end"
example      = "example" quoted-name "is" (name "=" literal)+
               ("expect" expression "=" literal)+ "end"
```

Law names use backticks. Text/metadata use double quotes with escapes. Named
refinement declarations state their type versus value parameter kinds, including
forward references; the compiler validates their arity and argument kinds.
Lowercase type names represent variables. `a :: Type` is a type parameter, not a
runtime value with a generator.

A generic law is specialized when invoked with concrete adapters. Its declared
capabilities must justify its operations; specialization resolves those
requirements for the actual types. `Integer` as a capability requires an integer
type. `Integer` in a concrete result signature denotes a representation-independent
mathematical integer. See [refinements and abstract integers](REFINEMENTS.md).

## Expressions and arithmetic

Application binds most tightly. The remaining precedence, highest first, is:
unary `!`/`-`, composition `.`, multiplication/division, addition/subtraction,
comparisons (`==`, `!=`, `<`, `<=`, `>`, `>=`), `&&`, then `||`.
Comparisons do not chain. Arithmetic associates left; composition associates
right. An adjacent numeric sign remains part of an argument: `f -42` applies `f`
to negative 42. Write `x - 42` for subtraction.

Assertion `=` differs from Boolean `==`. `implies` guards its following
proposition; `and` requires both assertions. Parentheses determine the scope of a
shared guard. Both Boolean operators and implications short-circuit.

Literals acquire types from declared context. Unconstrained integers have type
`Integer`; decimal tokens have type `Decimal`. An annotation such as
`(127 :: Int8)` specifies context. A declared float context can type a decimal
token directly, but an explicitly constructed exact Decimal is not implicitly
converted into a float.

Integer `+`, `-`, `*`, and negation produce exact `Integer` results. Decimal
dominates integer/Decimal combinations; Rational dominates exact combinations
involving Rational. Exact `/` returns Rational. `prelude.quot` truncates integer
quotients toward zero; `prelude.rem` is the associated remainder. Division by
zero fails when evaluated. Explicit numeric conversions use `prelude.Type`.
Exact/inexact mixing otherwise fails type checking. IEEE arithmetic widens float
or complex precision as required; equality treats NaN as unequal and signed
zero as equal. Decimal rounding is explicit, with a scale and ties-to-even rule.

Passing a computed exact result to a bounded adapter argument performs a checked
conversion. It never wraps, truncates a fraction, or silently changes precision.
Adapter results are validated against the declared domain before use. See the
[primitive reference](PRIMITIVES.md) for all domains and helpers.

## Refinements and executable contracts

Refinements are pure Boolean predicates over a value and preceding binders.
They cannot call user adapters. Dependent inputs are generated in order;
shrinking preserves their predicates. Bounds such as `y > Int8.max - x` are
computed with exact arithmetic and can drive a dependent generator. If a chosen
`x` has no possible `y`, generation retries earlier inputs. Search exhaustion
fails explicitly rather than passing a property with no valid cases.

Contracts check preconditions, evaluate an adapter once, validate the result,
and then check postconditions against that same result. Predicate errors are
contextual failures, not rejected samples. Small finite domains are enumerated;
other domains use target property frameworks. `machineBits: 32 | 64` controls
machine-integer domains independently of the compiler host architecture. Native
machine-sized adapter bindings additionally verify the executing architecture.

## Compiler stages and public API

The parser retains source ranges. Resolution and inference check names, kinds,
capabilities, contextual literals, and generic specializations. Elaboration
produces typed core expressions with resolved declaration/binder IDs, explicit
arithmetic evidence and conversions, plus an authoritative proposition tree.
Refinement declarations become predicates on quantifiers and contracts; targets
do not interpret refinement syntax.

An independent core validator checks scopes, kinds, operand/result types,
capability evidence, and conversions. A pure core evaluator supports deterministic
domain checks and reference tests. The testing planner computes finite cases,
boundaries, and dependent generator requirements. All eight emitters consume
that plan and the core, without importing source syntax or inference.

`check`/`expand` report semantic validity. `planGeneration` additionally reports
execution feasibility, including empty finite domains. Source syntax errors,
semantic errors, core invariant failures, and generation errors have distinct
diagnostic codes. Runtime failures identify the law/example or adapter contract.
Parsed expressions retain real source ranges; synthesized expressions identify
the declaration that caused their creation.

API schema v3 uses separately defined wire views, with lossless tagged scalar
values. It does not serialize internal AST constructors. See the
[API migration guide](API-MIGRATION.md).

## Roadmap

0.11 elaborates natural-indexed families to erased data, measures and
refinements. The Core type model distinguishes type arguments from index
arguments, but that representation is not a claim that arbitrary dependent
programs are accepted. External type bindings and custom generator bindings
(0.10) configure native representations alongside the typed testing plan and do
not change source-language typing or equality; see
[the binding reference](NATIVE-BINDINGS.md).

### 0.12 Proof-producing dependent layer (released)

- Index equalities in checked definitions are discharged statically. Adapter
  results remain runtime-checked.
- Linear `Natural` arithmetic over measures is solved exactly, with unfolding
  on known constructors and induction through recursive calls.
- Evidence is recorded for every contract obligation as `proved` or
  `runtime-checked`, and reported by `lawspec check` and the API.
- Proved definition postconditions produce no runtime checks.
- Checked definitions may return indexed families. See
  [proved indices](#proved-indices-and-evidence).

Still open, for evaluation in later releases: index equalities between sibling
fields (perfect trees whose subtrees share one index), non-linear indices, and
GADTs that refine type arguments.

### 0.13 Wlaschin-style domain modeling primitives

- Semantic wrappers and constrained primitives.
- Make illegal states unrepresentable.
- Explicit domain workflows and state distinctions.

These build on 0.10 native bindings and 0.11 refinements.

### 0.14 Cross-unit imports and packages

- Reusable law, type and refinement libraries.
- Versioning and namespacing, including constructor names scoped to their unit.
  Today every unit compiled together needs distinct constructor names.
- Publishable behavioral contracts.

### 0.15 Evidence/discharge model

Each obligation reports how it was discharged:

- `PROVED`: discharged statically, by 0.12 evidence or definition proofs.
- `EXHAUSTIVELY CHECKED`: every value of a finite domain was checked.
- `PROPERTY TESTED`: generated cases, examples and boundaries.
- `RUNTIME CHECKED`: adapter contracts and checked codecs at native boundaries.
- `ASSUMED / EXTERNAL`: native adapters and bindings taken on trust.

## Generated project formatting

`lawspec init --target java` creates a readable Maven scaffold; Kotlin init
likewise expands Gradle blocks with two-space indentation. `--minify` explicitly
selects compact scaffolds and configuration JSON. `generate` and `examples`
accept the same flag for generated source. The mode is per invocation and does
not become a project default. Init preserves existing build files, and generation
preserves user-owned adapters regardless of formatting mode.

Generated runtime support and checked definitions belong in source directories;
framework-specific property helpers belong in test directories. Both follow
custom layout settings. Python uses PEP 8: four-space indentation, 79-column
code, and 72-column prose. Other targets follow Google language guidance where
applicable, with standard Rust formatting. Formatting is deterministic in the
native and WASM compilers; generation does not download or invoke a formatter.

See [the release notes](RELEASE-0.10.md) for compatibility and scope, and the target
guides for formatting verification and native representation details.
