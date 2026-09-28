# Python backend

Python output follows [PEP 8](https://peps.python.org/pep-0008/): four-space
indentation, a 79-column code target, 72-column prose comments/docstrings, and
two blank lines between top-level definitions. Explicit `--minify` permits
compact layout while preserving Python indentation and semantics.
`tools/python-formatting-integration.mjs` checks generated runtime, adapter,
definition, and test files with pycodestyle 2.14.0 at both machine widths. It
also compares readable and compact syntax trees, including literal contents.

Use Python 3.13 or later. Generated tests use Hypothesis; generated data classes,
scalar operations, and schema validation do not depend on a test framework.

## Native structural values

| LawSpec type | Adapter representation |
| --- | --- |
| `List a` | `list[A]` |
| `Maybe a` | `lawspec_schema.Maybe[A]`, with `Nothing` and `Just` variants |
| `Either a b` | `lawspec_schema.Either[A, B]`, with `Left` and `Right` variants |
| User-defined products and sums | Named generic dataclasses in `lawspec_data` |
| `Nullable a`, `Optional a` | Tagged `lawspec_runtime.Presence` values |

`Nothing()` differs from `Just(Nothing())`. `Left(value)` differs from
`Right(value)`. These algebraic variants are separate from the interoperability
states represented by `Nullable`, `Optional`, `Null`, and `Undefined`.

For example, this declaration:

```lawspec
type Tree (a :: Type) is
  Leaf value :: a
  Branch children :: List (Tree a)
end
```

produces a generic `Tree` base and `TreeLeaf` and `TreeBranch` dataclasses. A
product has one variant: `Pair` with constructor `Pair` produces `PairPair`.
When names conflict across units or between types and variants, the compiler
plans distinct names using their Core identities. Use the emitted declarations
and adapter annotations as the authoritative names.

Native pattern matching works on the generated variants:

```python
import lawspec_data as data


def count_leaves(tree: data.Tree[int]) -> int:
    match tree:
        case data.TreeLeaf():
            return 1
        case data.TreeBranch(children=children):
            return sum(count_leaves(child) for child in children)
    raise TypeError("unknown Tree variant")
```

Classes are frozen and use slots. Container payloads are copied when crossing
adapter boundaries, so modifying a native list does not change another use of
the logical test input. An abstract base cannot be directly constructed; empty
types acquire no artificial variant.

LawSpec equality uses schema-directed comparisons, including IEEE NaN and
signed-zero rules and Symbol identity. Generated dataclasses do not derive
Python field equality, whose container shortcuts can change those rules.

## Checked boundaries

Generated calls validate input values, convert them to native classes, call the
adapter, and validate its result. A field extracted from a native product can
be returned directly from an adapter with the corresponding LawSpec result
type. The same representation is used for nested and standalone containers.

Diagnostics identify constructor fields and list indices. Checks distinguish
Bool from integers, enforce primitive ranges under the selected `machineBits`,
reject invalid scalar text, and preserve raw code units, code points, and bytes.
Preconditions and postconditions operate on validated logical values.

## Total definitions

Checked total definitions emit reusable Python functions separately from adapters:

```lawspec
unit example.total

definition increment (x :: Int8) :: BigInt is x + 1 end
```

```python
from lawspec_definitions.example import total

symbols = {}
assert total.increment(symbols, 127) == 128
```

The first argument is the Symbol fixture context shared within an example.
Public signatures preserve native container and variant annotations; checked
conversion enforces element types, ranges, machine profiles, and nested presence
states at runtime. Errors include the resolved definition name. Source functions
and implementation bodies have no Hypothesis or pytest dependency.

`lawspec_definition_bodies.py` holds checked logical implementations. Public
modules under `lawspec_definitions/` provide native entry points grouped by unit.
Both belong in source directories and are generated-owned. Properties invoke
those checked bodies directly; definitions do not create adapter stubs. Unit
modules cannot shadow support modules or another unit's package. Native function
names such as `str` do not shadow built-ins used by generated validation.

Definition bodies and Python properties share typed expression rendering. Match
inputs are evaluated once, branches remain lazy, guards short-circuit, and exact
Decimal arithmetic is independent of Python's ambient rounding context.
Definitions must pass structural termination and definedness checks. Generic
definitions specialize to concrete uses. Refined signatures become checked
contracts, and refinement predicates may call checked definitions.

`tools/python-definitions-integration.mjs` checks standalone source calls,
properties, incorrect adapters, both machine profiles, custom layouts, compact
execution, and regeneration protection. The bundled Python corpus passes PEP 8 checks at 79 code columns and 72 prose
columns. The style audit includes the standalone total-definition fixture.

## Generation and layouts

Hypothesis composes tuples, alternatives, lists, and dependent strategies.
Recursive generation reserves each field's minimum node budget before sharing
the remainder. List length and element budgets vary together. Shrinking remains
native to Hypothesis and preserves the schema and structural size bound.
Small finite domains are enumerated; empty domains do not pass vacuously.

`lawspec_data.py` and `lawspec_schema.py` belong in the configured source
directory. `lawspec_data_strategies.py` belongs in the test directory. Configure
Python's import paths for those directories when using a custom layout.
Adapters remain user-owned. Unit names cannot shadow generated support modules.


Internal checked Core definition contracts now run at native and logical entry
points. Emission proves the obligations first; argument validation precedes
ordered preconditions, and result validation precedes postconditions. Contract
binders map explicitly to body inputs and the checked result. Refined source
signatures now produce these contracts through template proof and specialization.

`tools/portable-definition-contract-integration.mjs` exercises Python, JavaScript
and strict TypeScript with both machine profiles and layouts, without property
frameworks. It also verifies that deliberately corrupted results are rejected.
The fixture in `test/DefinitionContractFixture.hs` is shared with the JVM checks.

## Checking Python style

Set `LAWSPEC_CORE` to the native compiler, `LAWSPEC_PYTHON` to Python 3.13 or
later, and `LAWSPEC_PYCODESTYLE` to the `pycodestyle.py` source from version
2.14.0. Then run `node tools/python-formatting-integration.mjs`. The checker is
a development dependency; generating and executing runtime code does not
require it. Optional positional arguments select individual specification files.
