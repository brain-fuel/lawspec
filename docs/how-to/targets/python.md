---
id: lawspec.how-to.targets.python
kind: how-to
title: Set up Python
---
# Set up Python

## Requirements

- Python 3.13 or later. The runtime checks recognize 3.13 and 3.14.
- pytest 8.4.x and Hypothesis 6.x (6.135.26 or later).

## Create the project

```sh
npx lawspec init --target python
python3.13 -m venv .venv
.venv/bin/python -m pip install -e ".[test]"
npx lawspec doctor
npx lawspec generate
.venv/bin/python -m pytest
```

In a directory without build files, `init` creates a `pyproject.toml` with
`requires-python = ">=3.13"`, a `test` extra with pytest and Hypothesis, and
pytest settings `pythonpath = ["src"]` and `testpaths = ["tests"]`.

Set the target's `python` field in `lawspec.json` to the interpreter that has
the test dependencies, for example `.venv/bin/python`. `doctor` and the printed
test command use it.

## Layout

| Files | Directory |
| --- | --- |
| Adapters (yours): one module per unit, such as `example/atoi_codec.py` | `src` |
| `lawspec_runtime.py`, `lawspec_data.py`, `lawspec_schema.py` | `src` |
| Checked definitions: `lawspec_definitions/`, `lawspec_definition_bodies.py` | `src` |
| Tests and `lawspec_data_strategies.py` | `tests` |

With a custom `sourceDir` or `testDir`, update pytest's `pythonpath` and
`testpaths` to match. Unit names cannot shadow the generated support modules.

## Native representations

| LawSpec | Python |
| --- | --- |
| Integers, `CodePoint`, `CodeUnit16` | `int` (never `bool`) |
| `Bool` | `bool` |
| `Text`, `Char` | `str` |
| `Bytes` | `bytes` |
| `Decimal`, `Rational` | `Decimal`, `Fraction` |
| `Duration` | `datetime.timedelta` of whole microseconds |
| `Float32`, `Float64` | `float` |
| `Complex64`, `Complex128` | `complex` |
| `List a` | `list[A]` |
| `Maybe a` | `lawspec_schema.Maybe[A]`, with `Nothing` and `Just` variants |
| `Either a b` | `lawspec_schema.Either[A, B]`, with `Left` and `Right` variants |
| Products and sums | Named generic dataclasses in `lawspec_data` |
| `Nullable a`, `Optional a` | Tagged `lawspec_runtime.Presence` values |
| `Symbol`, `Unit`, `Null`, `Undefined`, raw text | `Symbol`, absence and `Raw` support values |

An adapter whose result is the abstract `Integer` returns any `int`.

`Nothing()` differs from `Just(Nothing())`, and `Left(value)` from
`Right(value)`. These algebraic variants are separate from the interoperability
states of `Nullable`, `Optional`, `Null` and `Undefined`.

A declaration such as:

```lawspec fragment
type Tree (a :: Type) is
  Leaf value :: a
  Branch children :: List (Tree a)
end
```

produces a generic `Tree` base with `TreeLeaf` and `TreeBranch` dataclasses. A
product, a type with one constructor, is a single dataclass named after the
type: `type Pair is Pair first :: Int8 second :: Int8 end` produces `Pair`.
When names collide across units, the compiler qualifies them; the emitted
declarations and adapter annotations are authoritative. Match on the variants
natively:

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

Classes are frozen and use slots. Containers are copied at adapter boundaries,
so mutating a list in one place cannot change another use of the same test
input. Generated dataclasses do not use Python field equality; LawSpec equality
is schema-directed.

Generated calls validate every argument and result. Diagnostics name
constructor fields and list indices. Checks distinguish `bool` from integers,
enforce ranges under the selected `machineBits`, reject invalid text, and
preserve raw code units, code points and bytes. Python integers have no native
machine width, so the profile is enforced by validation.

## Checked definitions

```lawspec
unit example.total

definition increment (x :: Int8) :: BigInt is x + 1 end
```

```python
from lawspec_definitions.example import total

symbols = {}
assert total.increment(symbols, 127) == 128
```

The first argument is the Symbol context shared within one example. Errors
name the definition. Definition modules have no pytest or Hypothesis
dependency. Decimal arithmetic is exact and ignores Python's decimal context.

## Generation and shrinking

Tests use Hypothesis strategies, composed for tuples, alternatives, lists and
dependent inputs. Shrinking is Hypothesis's own and keeps values within their
domain and size budget.

## Formatting

Output follows PEP 8: four-space indentation, 79-column code, 72-column
comments and docstrings, and two blank lines between top-level definitions.
`--minify` allows a compact layout that keeps Python's required indentation.
