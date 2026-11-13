---
id: lawspec.reference.prelude-algebra
kind: reference
title: Prelude laws and algebra
---
# Prelude laws and algebra

The prelude is an implicit unit, `prelude`, available in every source. It
defines reusable laws and the semantics of currying, conjunction, implication
and expected results.

## Prelude laws

The tables give template names and arguments. Apply a template with explicit
syntax such as `apply law "|left inverse| decode encode`.

### Functions and round trips

| Law and arguments | Checks, for every input | Requires |
| --- | --- | --- |
| `left inverse f g` | `f (g x) = x` | `Eq` on `x` |
| `round trip identity is preserved a b` | `b (a x) = x` | `Eq` on `x` |
| `equivalent f g` | `f x = g x` | `Eq` on the result |
| `idempotent f` | `f (f x) = f x` | `Eq` |
| `satisfies predicate` | `predicate x` is true | |
| `left inverse when predicate f g` | `predicate x implies f (g x) = x` | `Eq` on `x` |
| `involution f` | `f (f x) = x` | `Eq` |

`equivalent` can compare two predicates, because `Bool` has equality.
`satisfies` and `left inverse when` keep their condition, and its bindings, when
they are expanded.

### Algebra

`f` and `g` are binary operations, `inverse` is unary, and `e` and `zero` are
values. All of these laws require equality on the element type.

| Law and arguments | Equations checked for every quantified input |
| --- | --- |
| `commutative f` | `f x y = f y x` |
| `associative f` | `f (f x y) z = f x (f y z)` |
| `left identity f e` | `f e x = x` |
| `right identity f e` | `f x e = x` |
| `identity f e` | Both identity equations |
| `left absorbing element f zero` | `f zero x = zero` |
| `right absorbing element f zero` | `f x zero = zero` |
| `absorbing element f zero` | Both absorbing equations |
| `left distributive f g` | `f x (g y z) = g (f x y) (f x z)` |
| `right distributive f g` | `f (g x y) z = g (f x z) (f y z)` |
| `distributive f g` | Both distributive equations |
| `idempotent operation f` | `f x x = x` |
| `left inverse element f inverse e` | `f (inverse x) x = e` |
| `right inverse element f inverse e` | `f x (inverse x) = e` |
| `invertible f inverse e` | Both inverse equations |
| `left division f divideLeft` | `f x (divideLeft x y) = y` and `divideLeft x (f x y) = y` |
| `right division f divideRight` | `f (divideRight x y) y = x` and `divideRight (f x y) y = x` |
| `divisible f divideLeft divideRight` | All four division equations |

`idempotent operation` is the binary form; `idempotent` is unary.

**Divisible** means algebraic left and right division: `divideLeft x y` solves
`f x result = y`, and `divideRight x y` solves `f result y = x`. For a
non-commutative operation such as subtraction, with `x = 3` and `y = 5`, the
left solution is `-2` and the right solution is `8`. Recovery is checked in both
directions. These are total laws: a partially defined division needs an explicit
domain predicate and conditional equations.

`invertible` checks the supplied inverse. To specify a group, also check
`identity` and `associative`. The prelude states contracts; it does not supply
arithmetic implementations, and random tests do not prove that a structure is a
group.

Every row has an executable example in
[`algebra.lawspec`](../../examples/specs/algebra.lawspec), including both sides
of every combined law. Its examples use exact `Integer` values whose expected
results exceed `Int32` and machine bounds, so an adapter that wraps fails even
when modular arithmetic happens to satisfy the identities.

### Collection operations

`prelude.setOf`, `prelude.lookup`, `prelude.push` and the other collection
operations, and `prelude.compare`, are listed in
[collections](language/collections.md#operations).

## Currying and partial application

Arrows associate to the right and application to the left: `f :: a -> b -> c`
takes two arguments, and `f x y` means `(f x) y`.

```lawspec
unit example.addition

add :: Int32 -> Int32 -> Int32

law "|addition commutes| is
  definition :
    apply law "|commutative| add
  end definition

  example "|3 plus 5 and 5 plus 3 both produce 8| :
    x = 3
    y = 5
    expect add x y = 8
    expect add y x = 8
  end example
end law

law "|zero is an identity on both sides| is
  definition :
    apply law "|identity| add 0
  end definition

  example "|zero preserves 3 on either side| :
    x = 3
    expect add 0 x = 3
    expect add x 0 = 3
  end example
end law
end unit
```

- A partial application such as `add 1` can be passed to a unary law, and
  `sumFour 1 2` to a binary law. Partial applications also compose.
- Value parameters take literals directly: `` `left identity` add 0 ``, or
  `` `absorbing element` multiply 0 ``.
- The compiler specializes these expressions before emitting code.

Adapters take ordinary positional arguments (`add(x, y)`) in Java, Kotlin,
Python, JavaScript, TypeScript, Go and Rust, and curried arguments (`add x y`)
in Haskell. Argument order and types are preserved, including mixtures such as
`Text`, `Bool` and `Int32`.

The [currying example](../../examples/specs/currying.lawspec) partially applies
a four-argument function twice, formats four arguments of different types, and
composes after partial application, with exact expected outputs.

## Conjunction

`and` requires several conclusions in one law:

```lawspec
unit example.absorption
multiply :: Int32 -> Int32 -> Int32

law "|zero absorbs on both sides| is
  definition :
    for all (x :: Int32) =>
      multiply 0 x = 0 and multiply x 0 = 0 end for all
  end definition

  example "|3 times zero and zero times 3 both produce zero| :
    x = 3
    expect multiply 0 x = 0
    expect multiply x 0 = 0
  end example
end law
end unit
```

Quantification and implication extend over a following `and`:
`p x implies A and B` guards both conclusions. Write `(p x implies A) and B` to
guard only the first. A shared guard runs once per check, and a false guard
skips its whole consequence. Every conjunct is type-checked and emitted; within
one test, the first failing conjunct stops that test.

`lawspec explain` prints the whole conjunction and the scope of each condition.
In the API, a law's `assertion` tree is authoritative; see
[the API reference](api.md#laws-and-assertions).

## Predicates and implication

A predicate is a function returning `Bool`. `true` and `false` can appear in
expressions, example bindings and expected results. A Boolean expression on its
own is a law definition that must be `true`.

`condition implies consequence` checks the consequence only when the condition
is true. The condition must be a `Bool`. The consequence can be an equality,
another implication, a Boolean predicate or a reusable law. Nested implications
short-circuit in source order. Quantify inputs before using them.

```lawspec
unit example.parse_port

validPort :: Int32 -> Bool
render    :: Int32 -> Text
parse     :: Text -> Int32

law "|valid ports round trip| is
  definition :
    for all (x :: Int32) =>
      validPort x implies
      parse (render x) = x end for all
  end definition

  example "|ordinary port| :
    x = 443
    expect validPort x = true
    expect render x = "443"
    expect parse (render x) = 443
  end example

  example "|zero is rejected; the round trip is skipped| :
    x = 0
    expect validPort x = false
  end example
end law
end unit
```

- Explicit `expect` assertions always run, whatever the condition. A false
  condition skips only the law's consequence: invalid ports never reach
  `render` or `parse` through the law.
- An error raised by the predicate fails the test. It is not treated as false.
- Implication is logical implication, not generator filtering. Random tests
  still sample the whole input domain and count a false condition as
  satisfying the law. A narrow predicate may exercise few consequences in a
  random run, so add explicit examples for the important cases. Examples that
  expect both `true` and `false` catch predicates that are always one or the
  other.

The [complete port example](../../examples/specs/parse_port.lawspec) treats
1–65535 as valid and covers both endpoints, zero, negative values and 65536. The
[Boolean flags example](../../examples/specs/boolean_flags.lawspec) checks that
flipping twice restores both `false` and `true`.

## Expected results

Every `example` binds all the law's quantified inputs, then states one or more
results with `expect <expression> = <literal>`.

- The literal must have the expression's type.
- Expressions can use the example's inputs and the unit's functions, including
  compositions. Input names shadow function names.
- Expected results are written by you. They are never inferred by running
  your adapter.
- An example passes only when **all its expected results and the enclosing
  law** hold for its inputs. Random and boundary tests continue to check the
  general law.
- A failing assertion shows the compared values, and names the example, its
  input bindings and the expression. It stops that test only; other tests run
  independently.
- In Java, JavaScript and TypeScript a failing case of any kind (an example,
  a boundary case such as `boundary 3`, a generated case) ends with the law's
  inputs by name, `| inputs: userId = "a\uD800", retries = 3`. A text is shown
  as a quoted literal in which a character that would not be seen (a control,
  a lone surrogate, a no-break space) is an escape. When a side of the law
  fails instead of giving a value, the headline carries the cause, and a
  violated adapter contract names the argument values it was checked on. The
  other targets show the compared values and where they first differ.

A law may have no examples at all, but an example must have at least one
`expect`. Use `lawspec explain --view dev` to see a law's expansion, the input
names its examples must bind, and the expected results, without running any
adapter.


---
id: lawspec.reference.language.collections
kind: reference
title: Collections
---
# Collections

## Canonical authoring profile

In `1.0-rc.2`, `Set a` stores distinct elements in first-occurrence order.
Construction and membership require `Eq a`: equality compares candidates with
stored elements and detects duplicates. These operations do not require an
order. Iteration with `prelude.toList`, size and emptiness do not compare
elements and need no `Eq` requirement. Set equality ignores iteration order.

| Operation on `Set a` | Required capability |
| --- | --- |
| Construction, membership, insertion, removal, union, intersection, difference, equality | `Eq a` |
| Iteration, size, emptiness, accepting or returning an existing set | None for its elements |

For a concrete element type, the compiler resolves equality automatically.
A generic function that tests membership must declare `requires Eq a`.
Membership always requires equality; the canonical set removes the additional
ordering requirement imposed by the old `Keyed` representation.

Use `#S{3, 1, 3}` or `prelude.setOf [3, 1, 3]`; iteration produces `[3, 1]`.
Use `SortedSet a` and `prelude.sortedSetOf` when portable sorted iteration is
required. Its elements require `Keyed a`. Keyed maps retain their requirements.

IEEE equality is preserved: signed zeros compare equal, and a NaN is unequal
to itself. A stored NaN therefore does not make membership of that NaN true.
Canonical set values use the checked data representation on all targets; the
native collection mappings below describe `SortedSet`'s ordered representation.
Complete finite checking includes every observable storage order. `Set Bool`
has five inputs: the empty set, each singleton, and both orders of the two
Boolean members. `Set (Set Bool)` has 114 stored inputs: equal inner sets
retain their distinct iteration orders, but cannot coexist as duplicate outer
members. Enumeration reports incomplete coverage when the configured limit
is insufficient or the element domain is unavailable. A non-reflexive
member can repeat without comparing equal, so its storage domain is unbounded.

Property checking selects sampled native generation and shrinking; planning
those checks supplies no completed verification evidence. A complete singleton
input runs once. Each candidate and shrink must still satisfy element and
dependent input restrictions.

## Membership and predicates

Canonical membership accepts a List, Set, SortedSet, Queue, Stack, Deque or
Bytes. Bytes expose octets of type UInt8. These forms have the same meaning:

```text
prelude.member value members
value in members
value is in members
value must be in members
```

Membership requires `Eq` for the element type and uses language equality.
It evaluates the candidate and collection once, in that order. Comparisons
stop at the first equal element. `not (value in members)` negates the result.
Membership is nonassociative; parenthesize larger Boolean expressions.

`prelude.all predicate members` uses the same iterable domains as `any`.
It stops at the first false predicate and returns true for an empty collection.
The predicate's captured arguments are evaluated once, before traversal, even
when the collection is empty. It uses the checked universal element callback;
no new proof rule is introduced. ref:DEC-s1j-shared-failures

`prelude.any predicate members` asks whether a Boolean predicate holds for
at least one element. It visits elements in iteration order and stops at the
first true result; an empty collection gives false. It needs no element `Eq`
unless the predicate itself compares elements. Named and partially applied
checked functions can supply the predicate. Captured arguments are evaluated
once before iteration, including when the collection is empty. Mandatory
checks still reject undefined arguments or invalid predicate definitions
when no optional law verification is selected.

Literal collections take their element type from a candidate or predicate.
For example, a Float64 predicate gives `[1.0, 2.0]` Float64 elements.
Computed collections retain their own types; the operation does not silently
convert Decimal data into floating-point data or unwrap nominal types.

Maps select their domain explicitly with `prelude.keys`, `prelude.values` or
`prelude.entries`. Passing a map directly to membership or `any` is an error.
Sized stacks and queues expose their checked `prelude.sizedStackItems` and
`prelude.sizedQueueItems` operations; use those lists for membership or `any`.
Text substring matching remains explicit, for example `text contains fragment`.
Membership does not add text normalization, case folding or word boundaries.

The [native membership fixture](../../../test/fixtures/canonical-collection-membership.lawspec)
exercises these forms, IEEE equality, map selections and dependent sized
operations. Law verification remains independently selected: a planned native
predicate test is not a completed proof or exhaustive verification.

## Collection types

Use `SortedSet` for ordered collection semantics. `Set` uses
equality and first-occurrence order as described above.

Besides `List`, LawSpec has these built-in collections:

| Type | Holds |
| --- | --- |
| `Set a` | distinct elements, in first-occurrence order |
| `SortedSet a` | distinct elements, in the portable order |
| `KeyVal k v` | entries with distinct keys, in the portable order of the keys |
| `Queue a` | items, first in first out |
| `Stack a` | items, last in first out |
| `Deque a` | items, added and removed at either end |

`Entry k v` is a key/value pair, built with `Entry key value`. `Ordering` has
the constructors `Less`, `Equal` and `Greater`.

```lawspec
unit guide.collections

dedupe :: List Int32 -> SortedSet Int32
wordCounts :: List Text -> KeyVal Text Integer

function countWords (words :: List Text) (counts :: KeyVal Text Integer) ->
  KeyVal Text Integer is
  first matching case of words :
    when Nil then counts
    when Cons w rest then first matching case of prelude.lookup w counts :
        when Absent then countWords rest (prelude.put w 1 counts)
        when Present n then countWords rest (prelude.put w ((n + 1) :: Integer)
          counts)
      end case
  end case
end function

law "|dedupe agrees with sortedSetOf| is
  definition : for all (xs :: List Int32) => dedupe xs = prelude.sortedSetOf xs
    end for all end definition
end law

law "|word counts agree with the definition| is
  definition :
    for all (words :: List Text) => wordCounts words = countWords words
      (prelude.keyValOf []) end for all
  end definition
end law

law "|the latest put wins| is
  definition :
    for all (k :: Text) (v :: Integer) (w :: Integer) (m :: KeyVal Text Integer)
      =>
      prelude.lookup k (prelude.put k w (prelude.put k v m)) = Present w end for all
  end definition
end law
end unit
```

A unit that declares a type with one of these names, such as a `Stack` of its
own, uses its own type instead.

## Operations

Every operation is total and is written `prelude.<name>`. The `...Of`
operations build a collection from a list; they are also how a collection is
written as a value.

| Type | Operations |
| --- | --- |
| all six | `size`, `isEmpty`, `toList` (in iteration order) |
| `Set` | `setOf`, `member`, `insert`, `remove`, `union`, `intersection`, `difference` |
| `SortedSet` | `sortedSetOf`, `sortedSetMember`, `sortedSetInsert`, `sortedSetRemove`, `sortedSetUnion`, `sortedSetIntersection`, `sortedSetDifference` |
| `KeyVal` | `keyValOf` (a later entry for a key wins), `lookup` (a `Maybe v`), `put`, `delete`, `keys`, `values`, `entries` |
| `Stack` | `stackOf` (the last item is on top), `push`, `pop`, `peek` (a `Maybe a`) |
| `Queue` | `queueOf` (the first item is in front), `enqueue`, `dequeue`, `front` |
| `Deque` | `dequeOf`, `pushFront`, `pushBack`, `popFront`, `popBack`, `peekFront`, `peekBack` |

Popping or dequeuing an empty collection leaves it empty. `prelude.compare a b`
gives the `Ordering` of two keyed values. The collections' constructors are
internal: a law or definition cannot match on them.

## Sized stacks and queues

`SizedStack n a` and `SizedQueue n a` carry their size in their type, as
[indexed families](indexed-families.md). An operation that needs an item takes
a non-empty one, so it never has to decide what an empty one gives:

| Operation | Type |
| --- | --- |
| `prelude.sizedPush x s` | `SizedStack n a` to `SizedStack (n + 1) a` |
| `prelude.sizedPop s` | `SizedStack (n + 1) a` to `SizedStack n a` |
| `prelude.sizedTop s` | `SizedStack (n + 1) a` to `a` |
| `prelude.sizedEnqueue x q` | `SizedQueue n a` to `SizedQueue (n + 1) a` |
| `prelude.sizedDequeue q` | `SizedQueue (n + 1) a` to `SizedQueue n a` |
| `prelude.sizedFront q` | `SizedQueue (n + 1) a` to `a` |
| `prelude.sizedStackItems s`, `prelude.sizedQueueItems q` | the items, top or front first |

The empty ones are `SizedStackEmpty` and `SizedQueueEmpty`. Unlike the other
collections, their constructors (`SizedStackPush top rest`,
`SizedQueueFront front rest`) can be matched.

## The portable order

`SortedSet` elements and `KeyVal` keys need the `Keyed` capability: a total order
that every target agrees on. Canonical `Set` needs equality for membership and
duplicate detection, and does not acquire `Keyed` from its storage order.

| Keyed | Not keyed |
| --- | --- |
| integers, `Whole`, `Nat`, `Decimal`, `Rational` | `Float32`, `Float64`, `Complex` |
| `Bool`, `Char`, `CodePoint`, `Text`, `Bytes`, `Unit` | `Symbol`, functions |
| data, `List`, `Maybe`, `Either`, `SortedSet` and `KeyVal` whose fields are keyed | canonical `Set` |

The order:

- exact numbers by value;
- text by code point, bytes by octet, and `false` before `true`;
- lists element by element, a prefix first; `Absent` before `Present`;
- other data by constructor, then by fields left to right.

`SortedSet Float64` is rejected because `Float64` has no portable `Keyed` order.
`Set Float64` supports IEEE equality with the NaN caveat described above.
A definition that orders its arguments may require `Keyed a`.

## Native types

Canonical `Set` uses its generated checked data type, shown in the adapter's
signature. Its stored items retain first-occurrence order. `SortedSet`, maps
and the other collections use the native representations below. Their codecs
sort and deduplicate ordered sets and keep the last value for a repeated key.

| Target | `SortedSet` | `KeyVal` | `Queue`, `Deque` | `Stack` |
| --- | --- | --- | --- | --- |
| Python | `frozenset`; a sorted `tuple` for structured elements | `dict`; a `tuple` of pairs for structured keys | `collections.deque` | `deque`, top last |
| JavaScript, TypeScript | `Set` (`ReadonlySet`); a frozen array for structured elements | `Map` (`ReadonlyMap`); an array of pairs for structured keys | array | array, top last |
| Go | sorted `[]T` | sorted `[]Entry[K, V]` | `[]T` | `[]T`, top last |
| Java | `java.util.Set` | `java.util.Map` | `java.util.ArrayDeque` | `ArrayDeque`, top first |
| Kotlin | `Set` | `Map` | `ArrayDeque` | `ArrayDeque`, top last |
| Rust | `BTreeSet` | `BTreeMap` | `VecDeque` | `Vec`, top last |
| Haskell | `Data.Set.Set` | `Data.Map.Strict.Map` | `Data.Sequence.Seq` | `Seq`, top first |

Haskell projects need the `containers` package, which generated projects
list. Rust and Haskell generated data derive `Ord` when it is keyed.

## Generation

Collections are generated from generated lists, and shrink as lists do.
`Set` detects duplicates by equality without sorting. `SortedSet` and KeyVals
are sorted and deduplicated. Boundary values include the empty
collection, a single item, and two items.

## Limits

- `Deque` has no sized variant yet.
- `#S{1, 2}` constructs a canonical set; other collections use their `...Of`
  constructors.


---
id: lawspec.reference.language.sequences
kind: reference
title: Sequences
---
# Sequences

`Text`, `Bytes` and `List` are sequences. Code joins them, takes parts of
them, reads items by index, and turns octets and texts into each other.

```lawspec
unit guide.sequences

-- Kafka's member ids: a client id and a counter.
function memberId (client :: Text) (n :: Int32) -> Text is client ++ "-" ++
  prelude.textOf n end function

-- The octets of a key, summed.
function checksum (key :: Bytes) -> Integer is total (prelude.octets key)
end function

function total (xs :: List UInt8) -> Integer is
  first matching case of xs :
    when Nil then 0
    when Cons o rest then o + total rest
  end case
end function

law "|sequences| is
  definition :
    memberId "consumer" 3 = "consumer-3"
    and checksum (prelude.utf8 "ab") = 195
    and prelude.slice 1 3 "kafka" = "af"
    and prelude.at 1 [10, 20, 30] = Present 20
    and prelude.range 0 3 = [0, 1, 2]
  end definition
end law
end unit
```

| Operation | Gives |
| --- | --- |
| `a ++ b`, `prelude.append a b` | `a` then `b`: two texts, two `Bytes` or two lists of one type |
| `prelude.slice from to x` | the items of `x` from index `from` up to, not including, `to` |
| `prelude.take n x`, `prelude.drop n x` | the first `n` items, and the rest |
| `prelude.at i x` | `Present item` for the item at index `i` of a list, or of `Bytes` as a `UInt8`; `Absent` outside it |
| `prelude.length x` | how many items: code points of a text, octets of `Bytes` |
| `prelude.range from to` | the integers from `from` up to, not including, `to`, of their type |
| `prelude.octets b` | the octets of `Bytes`, a `List UInt8` |
| `prelude.bytesOf xs` | `Bytes` of a `List UInt8` |
| `prelude.utf8 t` | the UTF-8 encoding of a text, as `Bytes` |
| `prelude.textOf n` | an integer, written in decimal |
| `prelude.join separator texts` | a list of texts joined, the separator between each two |
| `prelude.split separator text` | the pieces of a text between occurrences of the separator, a `List Text` |
| `prelude.trim text` | the text without white space at its start and end |
| `prelude.isUnicodeWhitespace text` | whether every code point of the text is white space; true of the empty text |
| `prelude.trimAsciiControl text` | the text without the code points up to U+0020 at its start and end |
| `prelude.words text` | the runs of a text without white space, a `List Text` |
| `prelude.lines text` | the pieces of a text between line feeds, a `List Text` |
| `prelude.map function items` | the list of `function item` for each item of a list, in order |
| `prelude.filter predicate items` | the items of a list the predicate accepts, in order |

- Indices count from 0: code points of a text, octets of `Bytes`, items of a
  list.
- `slice`, `take` and `drop` are clamped to the sequence: an index before its
  start or past its end stands for the start or the end, so they never fail.
- Every operation is total, and means the same on every target.

## Pieces of a text

```lawspec
unit guide.pieces

-- A setting is a name, an equals sign and a value.
function settingName (line :: Text) -> Text is
  first matching case of prelude.split "=" line :
    when Nil then ""
    when Cons name rest then prelude.trim name
  end case
end function

law "|pieces| is
  definition :
    settingName " retries = 3" = "retries"
    and prelude.split "," "a,,b," = ["a", "", "b", ""]
    and prelude.words " one  two\tthree\n" = ["one", "two", "three"]
    and prelude.lines "a\n\nb\n" = ["a", "", "b"]
  end definition
end law
end unit
```

- `split` finds the separator from left to right and keeps empty pieces, so
  `prelude.join separator (prelude.split separator text)` is always `text`.
  An empty separator divides nothing: the result is the one text.
- `words` never gives an empty word. A text of white space only has none.
- `lines` ends a line at each line feed and gives no empty last line, so the
  empty text has no lines. A carriage return stays in its line; `trim`
  removes it.
- White space is the 25 code points of Unicode 17.0.0's `White_Space`
  property: tab to carriage return, space, U+0085, no-break space, and the
  spaces and separators U+1680, U+2000 to U+200A, U+2028, U+2029, U+202F,
  U+205F and U+3000. Every target uses this set, not its own library's.
- A proof does not look inside these built-ins: a law about them is
  evaluated and tested, and a solver result for one is "unsupported".

### Modelling a host's trim and blank tests

Two built-ins are named for exactly what they do, for laws about code that
uses a host's own text functions. Neither is a portable `trim`; `prelude.trim`
is.

- `prelude.trimAsciiControl text` removes every code point up to U+0020 (the
  C0 controls and the space) from both ends. That is what Java's
  `String.trim()` removes. It differs from `prelude.trim`: U+0000 to U+0008
  and U+000E to U+001F go, and U+0085, the no-break space and the other
  Unicode spaces stay.
- `prelude.isUnicodeWhitespace text` holds when every code point has the
  `White_Space` property, the set `trim` and `words` use, so
  `prelude.isUnicodeWhitespace text = (prelude.trim text == "")` for every
  text. It is close to Java's `String.isBlank()` and differs on eight code
  points, because `isBlank` follows `Character.isWhitespace`: U+0085, U+00A0,
  U+2007 and U+202F are white space here and not for `isBlank`; U+001C to
  U+001F are white space for `isBlank` and not here. A law that must agree
  with `isBlank` on those states them, or restricts its inputs.

```lawspec fragment
law "|host trims| is
  definition :
    prelude.trimAsciiControl "\0\31 a\tb \n" = "a\tb"
    and prelude.trimAsciiControl "\160a\160" = "\160a\160"
    and prelude.trim "\160a\160" = "a"
    and prelude.isUnicodeWhitespace " \t\160"
    and not prelude.isUnicodeWhitespace "\31"
  end definition
end law
```

## Mapping and filtering a list

```lawspec
unit guide.mapping

function double (n :: Integer) -> Integer is n * 2 end function

function isEven (n :: Integer) -> Bool is prelude.rem n 2 = 0 end function

function scaled (factor :: Integer) (n :: Integer) -> Integer is factor * n end function

law "|mapping and filtering| is
  definition :
    prelude.map double [1, 2, 3] = [2, 4, 6]
    and prelude.map (scaled 3) [1, 2] = [3, 6]
    and prelude.filter isEven [1, 2, 3, 4] = [2, 4]
    and prelude.map prelude.length (prelude.words "one three") = [3, 5]
  end definition
end law
end unit
```

- The function is a definition, a built-in, or either with its first
  arguments given, as for `prelude.any`. Arguments given this way are
  evaluated once, before any item.
- There is one `map`. Over a list it gives the list of results; over an
  `Either` it maps the success value, as on the
  [railway combinators](expressions-and-arithmetic.md#railway-combinators). The operand's type decides which. `f <$> xs`
  is the same `map`.
- `map` and `filter` take a `List`. Use `prelude.toList` first for another
  collection.
- A recursive definition may map itself over the parts of its argument, such
  as the children of a tree: each element is smaller than the list it is in.
- A proof does not look inside a `map` or `filter`: a law about one is
  evaluated and tested, and a solver result for one is "unsupported". The
  function's own definedness is still checked for every item.

## Case folding and substring predicates

`prelude.caseFold text` applies Unicode 17.0.0 full default case folding.
It uses the pinned C and F mappings, including expansions such as `ß` to `ss`.
It excludes Turkic overrides: `I` becomes `i`, and `İ` becomes `i` followed by
a combining dot. Unlisted code points retain their value. It adds no Unicode
normalization or word boundaries. Every target uses the same checked definitions
and [pinned upstream table](../../../vendor/unicode/README.md).

`prelude.textContains whole fragment` is a checked Boolean function with the
haystack first. It supports ordinary partial application:

```lawspec
unit guide.filename

function prohibited (name of type Text) -> Bool is
  let folded = prelude.caseFold name in
    prelude.any (prelude.textContains folded) ["shit", "piss", "fuck"] end let
end function
end unit
```

The [banner filename example](../../../examples/rc1/banner-filenames.lawspec)
returns an explicit rejection before checking dimensions. A prohibited name
remains a valid `Picture` value. The companion
[tuple](../../../examples/rc1/picture-tuples.lawspec) and
[anonymous record](../../../examples/rc1/picture-records.lawspec) examples
retain the two dimension representations from examples 48 and 49.
- A fold over `Bytes` is a recursion over its octets, as `total` is above.

## Limits

- A text is read by code point; there is no operation on grapheme clusters.
- `Bytes` cannot be decoded back into a text, for now.


---
id: lawspec.how-to.test-text-properties-and-idempotence
kind: how-to
title: Test text properties and idempotence
---
# Test text properties and idempotence

This guide shows two common properties of text-processing functions: agreement
with a reference implementation, and reaching a fixed point.

## Compare two text normalizers

```lawspec
unit example.slug

normalize :: Text -> Text
referenceNormalize :: Text -> Text

law "|normalizers agree| is
  definition :
    apply law "|equivalent| normalize referenceNormalize
  end definition
  example "|spaces become hyphens; punctuation is preserved| :
    x = "Hello, World!"
    expect normalize x = "Hello,-World!"
    expect referenceNormalize x = "Hello,-World!"
  end example
end law
end unit
```

The [slug example](../../examples/specs/slug.lawspec) compares two
implementations of ASCII-space replacement, with examples for empty, Unicode and
escaped text.

Each target uses its framework's own string generator:

| Target | Generator |
| --- | --- |
| Java | JetCheck `Generator.stringsOf(Generator.asciiPrintableChars())` |
| Python | Hypothesis `st.text()` |
| JavaScript, TypeScript | fast-check `fc.string()` |
| Go | Rapid `rapid.String()` |
| Haskell | Hedgehog `Gen.text`, with lengths 0–100 |
| Kotlin | Kotest `Arb.string()` |
| Rust | Proptest vectors of up to 64 `char`s |

Distributions differ between libraries. The generated tests therefore also run
fixed cases on every target: empty text, whitespace, Unicode, combining marks
and escaped control characters.

Text values contain Unicode scalar values. Surrogate code points are rejected.
To test arbitrary UTF-16 units or code points, use `Utf16Text` or
`CodePointText`; see [primitives](../reference/primitives.md).

## Check that a function reaches a fixed point

The prelude law `idempotent` requires `f (f x) = f x`. Applying the function a
second time must change nothing:

```lawspec
unit example.canonical_url

canonicalize :: Text -> Text

law "|canonicalization reaches a fixed point| is
  definition :
    apply law "|idempotent| canonicalize
  end definition
  example "|all trailing slashes are removed in one pass| :
    x = "https://example.com/path///"
    expect canonicalize x = "https://example.com/path"
  end example
end law
end unit
```

For JavaScript:

```javascript
export const canonicalize = value => value.replace(/\/+$/, "");
```

An implementation that removes only one trailing slash still satisfies some
random inputs, but fails the repeated-slash example. The
[canonical URL example](../../examples/specs/canonical_url.lawspec) uses removal
of all trailing slashes as a small fixed-point demonstration, not a complete
URL canonicalization algorithm.

## Mix text with other inputs

A property can quantify over several inputs of different types. The
[mixed-input example](../../examples/specs/mixed_inputs.lawspec) combines `Text`
and `Int32` in one property and one example.


---
id: lawspec.reference.language.failures
kind: reference
title: Typed failures
---
# Typed failures

A procedure that can fail says what it fails with, and a law says which
failure it expects. Failures are values of a data type, so a law checks them
with a constructor pattern. For `Fail E`, `raise` and `prelude.attempt`, see
[abilities](abilities.md#failing).

```lawspec
unit guide.failures

type PaymentError is one of
  | Declined of type record{ message :: Text}
  | Blocked
  | TooLarge  of type Int32
end type

procedure charge (cents :: Int32) -> Int32 fails with PaymentError is
  if cents > 100000 then raise (TooLarge 100000) else
    if cents < 0 then raise (Declined record{ message = "a negative amount"})
    else cents end if end if
end procedure

law "|large charges fail as too large| is
  definition :
    for all (cents :: Int32 where cents > 100000) => charge cents fails with
      TooLarge _ end for all
  end definition
end law

law "|negative charges are declined, and say why| is
  definition :
    for all (cents :: Int32 where cents < 0) =>
      charge cents fails with Declined record{ message = _} message contains
    "negative" end for all
  end definition
  example "|minus one| :
    cents = -1
    expect charge cents fails with Declined record{ message = _}
    expect !(charge cents fails with Blocked)
  end example
end law
end unit
```

## `fails with`

`e fails with P` holds when `e` raises a failure that matches the pattern
`P`:

- `P` is a [constructor pattern](matchers.md#constructor-patterns):
  `Declined _`, `TooLarge 100000`, `Blocked`.
- It is false when `e` raises a failure of another constructor, and false
  when `e` gives a value instead.
- `e` must be something that can fail: its failure type comes from what it
  calls. If nothing in `e` can fail, the law is an error.

`e fails with P message contains "text"` also checks a `Text` field named
`message` in the alternative's explicit record payload. The payload can be an
anonymous or named record. A constructor without that field does not match;
an unnamed `Text` payload does not acquire a message role. Substring matching
is case-sensitive.

In an example, `expect e fails with P` states the expectation; `expect`
without `=` takes any `Bool`.

## Native failures

A native adapter's failures reach a law through the `Fail` ability, so
`fails with` checks them like any other:

```lawspec fragment
refund :: Int32 -> Int32 fails with PaymentError
async settle :: Int32 -> Int32 fails with PaymentError

law "|refunds over the limit are too large| is
  definition:
    for all (cents :: Int32 where cents > 5000) =>
      refund cents fails with TooLarge 5000
    end for all
  end definition
end law
```

The native code raises the runtime's `Fail` with a value of the failure
type, synchronously or from an async adapter:

| Target | Raising a failure |
| --- | --- |
| Python | `raise ls.Fail(data.PaymentErrorTooLarge(5000))` |
| JavaScript, TypeScript | `throw new ls.Fail(new data.PaymentErrorTooLarge(5000))` |
| Go | `panic(LawSpecFail{Value: PaymentErrorTooLarge{Value: 5000}})` |
| Java | `throw new LawSpecRuntime.Fail(new lawspec.data.PaymentError.TooLarge(5000))` |
| Kotlin | `throw LawSpecRuntime.Fail(lawspec.data.PaymentError.TooLarge(5000))` |
| Rust | `ls::fail(PaymentError::TooLarge { value: 5000 })` |
| Haskell | `throwIO (LS.Fail (Data.PaymentErrorTooLarge 5000))` |
| Erlang | `lawspec_beam_effects:fail({payment_error_too_large, 5000})` |
| Elixir | `:lawspec_beam_effects.fail(%LawSpec.Data.PaymentErrorTooLarge{value: 5000})` |
| Gleam | `failures.fail(data.PaymentErrorTooLarge(5000))`, importing `lawspec/failures` |

On the BEAM targets, the boundary checks the failure value against the
declared type, including bound native representations. `prelude.attempt`
catches the matching `Fail` ability; an unrelated exception remains an
exception.

An application that raises its own exceptions maps them to constructors in
`lawspec.edn` under `failures` (see [Handlers](handlers.md)); that mapping
is the implementation plane, never part of a law. A mapped constructor with
one `Text` payload gets the exception's message; a constructor pattern such as
`fails with Rejected "negative"` checks that payload directly. Automatic native
exception mappings support payload-free alternatives, a single `Text`
payload, and a chain of single-field records ending in `Text`, such as
`Declined of type record{message :: Text}`. Named and anonymous products keep
their resolved constructor identities; concrete generic arguments are
substituted before construction. Multiple fields, alternative choices,
recursive products, handles and indexed or existential payloads require an
explicit adapter. Mapping supplies only the message, never invented values
for other fields. The ordinary boundary validates the constructed payload,
including refinements; a rejected message remains an error.
The archived 0.24 suites
`examples/specs/failures.lawspec` and `examples/specs/handler_bindings.lawspec`
show both.


---
id: lawspec.reference.native-bindings
kind: reference
title: Native bindings
---
# Native bindings

Native bindings connect LawSpec data types, adapters and generators to existing
application code. This page specifies the configuration and what each target's
generated code does with it. For step-by-step use, see
[Bind native types and functions](../how-to/bind-native-types.md) and
[Write custom codecs and generators](../how-to/custom-codecs-and-generators.md).

## Configuration

Bindings are set per target in `lawspec.edn` (`targets[].nativeBindings`) or in
a compiler request (`nativeBindings`): API schema 5 and the current language
profile. The fields include `types`, `functions`, `generators`,
`rustCrate`, `goImports` and `erlangIncludes`; their shapes are in the
[API reference](api.md#native-bindings).

- Declarations are named by resolved identity: `<unit>::type::<Name>` for data
  types and `<unit>::<name>` for adapters.
- Native references are arrays of identifier segments, never code.
- A type binding maps the type, every constructor and every field, or names a
  `codec` pair. It cannot do both.
- Constructor `style` is `record` (the only constructor of a product),
  `variant` (an alternative with fields) or `unit` (an alternative without
  fields).
- A unit with function bindings must map every adapter it declares. Its adapter
  file becomes a generated bridge.
- Generic generator factories are resolved with one argument per type
  parameter.
- A [handle](language/models.md#handles)'s type binding may give
  `arguments`: the native class's type arguments, written in Kotlin, such as
  `["kotlin.Int"]`, or `[]` for a class that is not generic. Generated
  Kotlin then names the handle's type in full, as in
  `ConcurrentLinkedQueue<kotlin.Int>`, instead of `kotlin.Any`. Other
  targets ignore it; Java keeps `Object`.

The current authoring profile also accepts `names`, which explicitly chooses a generated public function
name. This applies to checked definitions and adapters, preserving declaration
identity, type, body, contracts and every call to the declaration:

```json
{
  "names": [
    {"declaration": "example::\"|adds value|", "name": "addAnotherValue"}
  ]
}
```

Names use portable ASCII identifiers starting with a lowercase letter. Each
target still applies its naming and keyword rules. Unknown identities,
duplicate overrides and malformed identifiers are errors. A collision after
overrides remains an error; generated public names never acquire automatic
suffixes. A name override supplies no native implementation and creates no
native bridge on its own. The compiler requires schema 5 and the explicit
`1.0-rc.2` profile for this field. The `rc1-native-names` acceptance suite checks
two colliding source spellings with distinct behavior on every target.

## Structural payload layouts

Grouped payloads use explicit structural paths and native argument positions:

```json
{"field": "value", "path": ["last"], "argument": 0, "native": "tail"}
```

`field` names a constructor field; `path` descends through anonymous records.
Every native field in such a layout supplies both `path` and `argument`.
Arguments must cover zero through the field count minus one exactly once.
The compiler checks complete coverage without overlapping paths, missing fields,
nominal unwrapping or implicit width conversion. Configuration array order does
not change constructor argument order. A path may stop at a whole typed field;
its existing native conversion still applies.

Bindings specify native argument order explicitly through positions and nested paths. Python, JavaScript, TypeScript, Java, Kotlin, Scala, Rust, Go, Haskell,
F#, Swift, Erlang, Elixir, Gleam and Groovy's Java bridge currently pack and unpack
them. JVM codecs use
the resolver's packing tree and ordinary schema construction. Rust derives moves and
recursive boxing from that same tree; adapter arguments and results reaching a
nested layout pass the existing schema validator at the selected machine width.
Go builds records through its ordinary schema; Haskell's existing codec
validation surrounds structural packing and pattern projection. In JVM, Rust,
Go and Haskell bridges, unmapped records retain canonical concrete fields and
their nominal children, including recursive children; generic parameters keep
their supplied directional codecs.
Conversion locals preserve native argument order independently of record order.
F# and Swift use native type aliases in their shared data family, including
generic arguments. Their codecs pack and project the checked structural tree;
Swift checks each nested tag and arity before projecting its fields. Entries
validate inputs reaching a layout before calling native code, and the existing
schema validation checks native results. Native types need no extra equality
or display implementation for conversion.
The BEAM targets carry the checked packing tree and applied leaf types into
their shared schema. Conversion substitutes generic arguments, converts leaves
in native argument order, and retains logical validation before encoding and
after decoding. Erlang record fields use the supplied header, Elixir uses
struct fields, and Gleam's compiled constructor helper determines actual tuple
positions; no target guesses them from source field order. Existing opaque
child-codec conversions continue to cross the canonical and bound schemas.
Scalar, nested record and enclosing constructor validation remains mandatory.
C# and Clojure retain their broader native-type-binding restrictions and
reject nested layouts explicitly. Target-independent
configuration correspondence does not establish target generation or native
behavior.
Indexed and existential constructor layouts remain unsupported.

## Async adapters

An [async adapter](language/async-functions.md) may be bound like any other. Its
native function or method uses the target's native concurrency, and the bridge
converts the result after the asynchronous call completes.

| Target | The native returns | The bridge |
| --- | --- | --- |
| Python | a coroutine (`async def`) | `async def`, awaiting it |
| JavaScript, TypeScript | a `Promise` | `async function`, awaiting it |
| Java | a `CompletableFuture` of the boxed type | converts with `thenApply` |
| Kotlin | from a `suspend fun` | a `suspend fun` |
| Go | a `LawSpecTask[T]` | a `LawSpecTask`, awaiting it in a goroutine |
| Rust | a future (`async fn`) | `async fn`, with `.await` |
| Haskell | an `IO` action | `IO`, converting with `fmap` |
| Erlang, Elixir, Gleam | the declared native value | calls the function in a monitored process, then converts the result |

A Unit result is `LawSpecRuntime.Value` in Java's future, and `LawSpecUnit` in
Go's task. A constructor bound to an async adapter is called at once, and its
bridge returns a task that is already done. On BEAM, the constructor instead
runs in the same monitored worker as other async native calls. On Kotlin, an async method binding
needs its handle's type binding, since Kotlin calls the method itself.

## Native actors

`actors` binds an existing Pekko Typed actor, or a Spring Boot actor starter
actor, to a LawSpec [actor](language/actors.md), so the actor's model checks
the application's own actor instead of LawSpec's. The behaviour and its
messages stay the application's; LawSpec generates the asks. Java and Scala
check Pekko actors, sharded entities included, and Java checks Spring
starter actors. Every other target rejects the field as unsupported.
The [Pekko how-to](../how-to/check-pekko-actors.md) checks apache/pekko-samples
this way.

```json
{
  "actors": [{
    "actor": "example.accounts::account",
    "behavior": ["example", "Account", "create"],
    "persistence": "event-sourced",
    "handlers": [
      {"handler": "deposit", "message": ["example", "Account", "Deposit"],
       "replyTo": true, "reply": ["example", "Account", "Balance"], "result": "balance"},
      {"handler": "close", "message": ["example", "Account", "Close"]}
    ]
  }]
}
```

| Field | Meaning |
| --- | --- |
| `actor` | The LawSpec actor, as `<unit>::<actor>`. |
| `behavior` | A static factory returning the actor's `Behavior<Command>`. It takes no arguments, or, for an event-sourced actor, its persistence id. |
| `behaviorArguments` | The factory's arguments, in order: `{"text": "Ghosh"}` passes a string, `{"probe": "left"}` the address of a probe named `left`. Not for a Spring, event-sourced or sharded actor. |
| `spring` | A Spring starter `SpringActor` component class, instead of `behavior`. Java only. |
| `persistence` | `"event-sourced"`: the actor recovers its state from its journal. The checks give each run's actor a fresh persistence id on Pekko's in-memory journal. |
| `entity` | The sharded entity's `EntityTypeKey`, a static field. The entity runs under Cluster Sharding, and every handler takes the entity's id, a `Text`, first. |
| `handlers` | One entry for each of the actor's handlers, and no others. |

Each handler entry gives:

- `handler`: the handler's name in the actor.
- `message`: the message class. Its constructor takes the handler's arguments
  after the state, in order, converted by the native codecs, then the
  `replyTo` address when `replyTo` is true.
- `messageFactory`: instead of `message`, a static method that takes the same
  arguments and returns the message. Use it when the message's constructor
  takes the application's own classes that no codec makes.
- `replyTo`: whether the message carries an `ActorRef` to answer. A handler
  with a result must have one.
- `reply`: the class of the answer, the type argument of the `replyTo`
  address. A handler without a result may still name one, as an
  acknowledgement whose content is ignored.
- `replyArguments`: the reply class's type arguments, for a generic reply
  such as `StatusReply<Summary>`. The message then gets a reply address of
  that type, and the result accessor reads it.
- `result`: the accessor on the reply that gives the handler's result,
  converted by the native codecs. Without it, the reply itself is the result.
- `resultField`: instead of `result`, a public field of the reply that holds
  the result.
- `caller`: when true, the handler's first argument is its caller, which the
  actor knows by address, as the dining hakkers' chopstick knows its hakker.
  Each caller gets one address for the whole run, and its messages carry it
  in place of a fresh `replyTo`. With a `reply`, the result is the next
  reply that address receives; without one, the message is sent with `tell`.
  One caller's messages go one at a time.
- `messageValue`: instead of `message`, a static field holding the message,
  such as a Java enum constant or a Scala case object. The handler takes no
  arguments and has no result.
- `replyCases`: instead of `result`, the result from which class the reply
  is, as `{"Taken": true, "Busy": false}`. Each key is a class beside the
  `reply` class. The values are all `Bool` or all `Text`, the handler's
  result type.

An actor that answers nothing is observed through probes, as Pekko's
`TestProbe` observes one. Each `{"probe": name}` behaviour argument is a
probe: LawSpec spawns it before the actor and passes the actor its
address, typed as the factory's parameter. A probe stands in for another
actor, so the actor's messages to that actor reach the probe. A probe
handler names its `probe` and one of:

- `hears`: the class of the next message the probe receives, in place of
  `message`. The step sends nothing; it fails when the probe receives
  nothing within the ask timeout, or a message of another class. A handler
  with a result reads it from the heard message with `result` or
  `resultField`.
- `answers`: a class the probe heard. The step sends `message` to the
  address in the last such message's `answerField`, a public field or
  accessor. With `replyTo`, the message's last argument is the probe's
  address, so the actor sees the answer come from the probe. The handler
  has no result.

A model actor with a `time passes by r` line has the step `timePasses`,
which needs no handler entry. Its actor runs on Pekko's `ManualTime`, its
own test kit with a virtual clock, so its timers fire only when a step lets
time pass. The step advances the clock by the `Duration` the reference
returns for the model's state before it. Time passes only in sequential
runs: parallel histories leave the step out. An actor with the line that is
not bound to a Pekko behaviour, or is persistent or sharded, is reported
`unsupported`. ref:DEC-tell-only-actors ref:DEC-time-passes

The checks spawn the behaviour in Pekko's `ActorTestKit` and run the actor's
model against it: generated runs with injected crashes, shrinking, model
invariants, parallel histories and linearizability, and the actor's
scenarios. Each handler is asked with `AskPattern`; a handler without a
`replyTo` is sent with `tell`. A crash is a private message, handled after
the messages sent before it: an interceptor around the behaviour turns it
into an exception, so Pekko's supervision restarts the behaviour. An
event-sourced actor is instead stopped and started again with the same
persistence id, as Pekko's `EventSourcedBehaviorTestKit` restarts one, and
recovers from its journal. A sharded entity runs in a one-node cluster in the
test kit: LawSpec starts sharding for an entity type named after the bound
key, with the bound behaviour wrapped in its crash interceptor, so the
application's own sharding setup does not run. Each run's entities are its
own, and a crash restarts every entity the run has started. The model's state then follows the actor's
`restart from` reference, or its start without one; an event-sourced actor
that keeps its state needs a reference that keeps the model's. A told
message whose events are still being written when the crash comes may be
lost, as in production, so bind an acknowledgement for a handler whose
effect must survive a crash.

A reply that does not arrive within the ask timeout fails the run with the
handler and its arguments; it never passes. The timeout is
`LAWSPEC_ASK_TIMEOUT_MS` milliseconds, 3000 by default.

The native actor's state is private. An actor whose `abstract` function or
invariants read its state cannot be bound; state the property over the model
instead. Binding validation also rejects:

- an unknown actor, a missing, unknown or repeated handler, and a native
  function binding for one of the actor's adapters;
- a handler with a result but no `replyTo` or `reply`, a `result` without a
  `reply`, and a `reply` without a `replyTo`;
- both `result` and `resultField`, not exactly one of `message`,
  `messageFactory`, `messageValue` or `hears`, `replyArguments` without a
  `reply`, and a `caller` with no argument or with a `replyTo`;
- an unknown or repeated probe, a probe handler that neither hears nor
  answers or that has a `caller`, `hears` or `answers` without a `probe`,
  `hears` with arguments, `replyTo`, `reply` or `answers`, `answers` without
  `answerField` or with a result or `reply`, a `messageValue` with
  arguments, `replyTo`, `caller` or `reply`, and `replyCases` with `result`
  or `resultField`, on a handler with no result, or with values that are not
  all `Bool` or all `Text` as the result is;
- an `entity` whose handlers do not take a `Text` first, an event-sourced
  sharded entity, and a caller of a sharded entity (all unsupported);
- several reply classes for one handler, including a stream of replies;
- a start that takes arguments, and handlers that are async, use abilities,
  or take or return functions or other actors' handles.

On Scala, `behavior` names an object's factory, `example.Account.create`,
which takes `()` or, for an event-sourced actor or a sharded entity, its
persistence or entity id. Messages are built with `Message(arguments...,
replyTo)`, so Scala case classes, Java classes and `messageFactory` methods
all work, and a result accessor or `resultField` is read as `reply.balance`.
`replyArguments` type the reply as `StatusReply[Summary]`, and an `entity`
may name a Scala DSL `EntityTypeKey`. The generated wiring sits in the
behaviour's package and calls the same Java checker, so the checks are the
same as on Java. A Scala `spring` binding is rejected.

A `spring` binding names a `SpringActor` component. A Spring context holds the
starter's actor support and that component, so the component gets Spring's
dependency injection; beans it needs from the rest of the application are not
in that context. Each run's actor is the behaviour the component's `create`
returns, with the run's actor id as its context's `actorId()`, compiled to Pekko
by the starter's own compiler and run in the same `ActorTestKit`, with its own
supervision strategy inside LawSpec's crash interceptor. Each handler's
`message` is an `AskCommand` of the reply class: its constructor takes the
handler's arguments, and the check sets its reply address as the starter's
ask does, so `replyTo` is true for every handler with a reply. Event-sourced
Spring starter actors are rejected as unsupported for now; bind the Pekko
behaviour instead. The application's build supplies the starter 1.0.0 and
`pekko-actor-testkit-typed_3` and `pekko-persistence-testkit_3` 1.7.1 for
the tests, as for a Pekko actor. The checker uses the
starter's internal `PekkoBehaviors` and `PekkoActorRef` classes, which have no
compatibility promise across starter releases, so the starter is pinned.
ref:DEC-spring-actor-starter

The Java compiler checks the rest of the agreement: the generated wiring
calls each message constructor with the codecs' native types and reads each
result accessor into the result's codec, so a mismatched type does not
compile. The actor's adapters become a generated bridge whose methods say the
native actor runs them. The application's build supplies Pekko 1.7.1:
`pekko-actor-typed_3` (and `pekko-persistence-typed_3` for an event-sourced
actor, `pekko-cluster-sharding-typed_3` for a sharded entity), with
`pekko-actor-testkit-typed_3` and `pekko-persistence-testkit_3` for the
tests. The wiring is generated in the behaviour's own package (its
reference's leading lower-case names), so it can name messages that are not
public. ref:DEC-native-actor-binding ref:DEC-pekko-sample-suites

## Validation

`check` resolves bindings once, against the typed declarations, and rejects:

- unknown types, constructors or fields;
- duplicate or incomplete mappings, and duplicate native field names;
- a `record` style on a type with several constructors, or fields on a `unit`
  constructor;
- incompatible type arities;
- `arguments` on a type that is not a handle, or an empty argument;
- malformed native references;
- unknown configuration fields.

`planGeneration` additionally rejects representations the target does not
support. Specifications without bindings keep their default generated types.

## Guarantees on every target

- **Bindings do not change meaning.** Arithmetic, equality, total definitions
  and refinements use LawSpec semantics. Bindings affect only native
  representations and the testing plan's generator choice.
- **Bridges are checked.** Conversions compose through type parameters,
  recursion, `List`, `Maybe`, `Either`, `Nullable` and `Optional`. They keep
  exact values, Symbol identity, distinct absence states, constructor
  contracts and both machine profiles. Adapter inputs and outputs are validated;
  an invalid native value is a failure, never a rejected sample. The built-in
  collections map to each target's own collections; see
  [collections](language/collections.md#native-types).
- **Generators stay native.** Factories return the framework's own generator.
  The tests compose and map it directly, without resampling or replacing its
  shrinker. Every sample and shrink is validated through the bridge.
  Refinements still filter it. Examples, deterministic boundaries and
  finite-domain enumeration run independently of it, and finite domains are
  enumerated without calling the factory. An exhausted custom generator never
  falls back to a built-in witness.
- **Source stays framework-free.** Bridges, codecs and runtimes are generated
  source with no test-framework dependency. Generator helpers are generated
  test code.
- **Application code stays yours.** Application models, hooks and factories
  are never rewritten. Optional scaffolds are user-owned.

## Evidence

A type binding is a `binding` obligation, `runtime-checked`. Codec hooks,
generator factories and bound functions are `codec`, `generator` and
`native-function` obligations, `assumed`.

## Targets

### Prolog

Function and handler references identify a dotted module and predicate; generator
factories construct ordinary Hypothesis strategies through Janus. Values cross
the boundary as canonical Prolog terms with full constructor identities. Custom
type/codec mappings, method/constructor call bindings and native exception
mappings are unsupported. See the [Prolog interface](prolog.md) for argument
order, module paths, factory signatures and execution scope.

### Rust

- References are paths; `crate` refers to the application library.
- `rustCrate` names the application library crate, so tests use its types and
  runtime rather than a second compiled copy.
- Construction uses struct and enum-variant literals with named fields.
  Direct mappings need recursive indirection compatible with the generated
  representation; other storage needs codec hooks.
- Hooks return `lawspec_runtime::Result<T>`. A generic hook receives
  `&dyn Fn(T) -> N` (or the reverse) per type parameter.
- Factories return a Proptest strategy of the native type and receive one boxed
  strategy per type parameter. They live in `<testDir>/support/`.
- An empty type parameter is supplied as a strategy with a rejecting filter,
  bounded by Proptest's rejection budget.

### Python

- References are module components followed by an exported class or function.
- Classes are checked by exact identity. Fields are read by attribute and
  passed as keyword arguments, so keyword-only dataclasses and reordered fields
  work.
- The bridge module `lawspec_native.py` and bound adapters are generated source.
  Python integers have no native width, so the machine profile is enforced by
  validation.
- Hooks return the converted value and raise on failure. Child converters
  receive native payloads.
- Factories are in importable test modules, receive one Hypothesis strategy per
  type parameter, and return a strategy of the native type.
- An empty type parameter is supplied as `st.nothing()`.

### JavaScript and TypeScript

- References are module path segments followed by an exported name. Source
  references resolve from the source directory; generator references from the
  test directory. Imports use `.mjs` (JavaScript) or `.js` (TypeScript).
- Payload classes receive one object keyed by the mapped field names; unit
  classes receive no arguments. Mapped fields must be own properties.
- Hooks return values or throw. Hook tables are copied when a schema is bound,
  so later mutation cannot change conversions.
- Factories return fast-check arbitraries and receive one arbitrary per type
  parameter. TypeScript scaffolds use `fc.Arbitrary<T>`.
- An empty type parameter is supplied as an arbitrary that throws when asked
  for a value. (An always-false fast-check filter could loop forever.)

### Java

- References are fully qualified type, constructor or static method names.
- Payload fields are read with accessor methods; constructors receive fields in
  LawSpec declaration order. `unit` refers to an enum constant. An empty record
  uses the `record` or `variant` style.
- `LawSpecNativeCodecs` composes typed codecs over the shared schema; generic
  recursive codecs are built lazily.
- Hooks take typed `java.util.function.Function` child converters and throw on
  failure. Generic payloads are checked `LawSpecRuntime.Value`s.
- Factories are static methods returning JetCheck `Generator`s, with one
  `Generator<T>` per type parameter. Scaffolds must be in a named package.
- An empty type parameter is supplied as a bounded rejecting JetCheck filter.

### Kotlin

- Payload mappings read properties and call constructors in LawSpec field
  order. `unit` refers to an enum constant or singleton object, compared by
  identity. Payload constructors are checked by exact runtime class.
- `LawSpecNativeCodecs.kt` and bound adapters are generated source.
- Hooks take ordinary function parameters, such as `(A) -> B`, and throw on
  failure.
- Factories return Kotest `Arb`s, with one `Arb<T>` per type parameter.
  Scaffolds are named objects in named packages.
- An empty type parameter is supplied as an `Arb` that fails when sampled.

### Go

Generated products with cyclic inline layouts use a sealed interface and one
variant. Ordinary products remain structs; slices and existing sum interfaces
already provide indirection. This applies through instantiated generic fields
and presence wrappers. Constructor names and codecs follow the same layout
decision. Source record identity and field order retain their meaning.

- References are one package-local identifier, or an alias from `goImports`
  and an exported identifier. Aliases are resolved to compiler-owned names, so
  they cannot shadow generated or framework imports. Duplicate aliases or
  paths, traversal segments and undeclared aliases are errors.
- Payload fields use exported names and keyed struct literals; `unit` refers to
  a constant. Application functions keep their own names (such as `AddFee`);
  generated bridges use separate names.
- Application symbols are reserved first. A generated type or variant that
  would collide receives a `Canonical` prefix, with a number if needed
  (`CanonicalBox`, then `Canonical1Box`). Logical identities do not change.
  Hooks that name generated types must use the emitted names.
- `lawspec_native_codecs.go` holds the framework-independent conversions; only
  reachable codecs are emitted per package.
- Hooks return `(value, error)`. Hooks that name generated types must live in
  the generated types' package, to avoid an import cycle.
- Factories are package-local functions returning `*rapid.Generator[T]`, with
  one generator per type parameter. Imported factories are never scaffolded.
- An empty type parameter is supplied through Rapid's discard control.

Go interfaces and generated model types are package-local. A consumer's
`Probe` interface is structurally compatible only when every method's parameter
and result types agree; two packages' generated nominal records do not become
identical because their fields match. A configured production factory is bridged
in each consuming package with that package's typed codecs. For factories shared
across packages, use an exported factory through `goImports`. Unqualified factory
and codec-hook names must be supplied in every package that uses them. Unbound
production handlers still require application implementations of the generated
local interface; a provider's user adapter is not copied into consumers. Remove
obsolete manual `New<Ability>Bound` workaround wrappers before regenerating;
user-owned adapter files are preserved. ref:DEC-s1j-shared-failures

### Haskell

- References are module components followed by a type, constructor or
  function.
- Records are constructed and matched by mapped field names, independent of
  declaration order. Application modules receive distinct import aliases, and
  references that shadow generated modules are rejected. Unit-returning
  application calls are forced before their result is encoded.
- Hooks return `Either String value`. Generic payloads are opaque; use the
  supplied child converters.
- Factories return Hedgehog `Gen`s, with one child `Gen` per type parameter.
- An empty type parameter is supplied as `Gen.discard`.

### Erlang, Elixir and Gleam

- All three targets share checked Erlang conversions. Public definitions and
  codec arguments use each target's canonical native types. Generic hooks take
  one conversion function per type parameter, after the value being converted.
- Erlang function references are `["module", "function"]`. A `variant`
  constructor uses a tagged tuple with fields in LawSpec declaration order;
  a `unit` constructor uses an atom. A `record` constructor uses the named
  record and mapped fields from `erlangIncludes`. For example,
  `"erlangIncludes": [{"path": "domain.hrl"}]` emits `-include("domain.hrl")`;
  `"library": true` selects `-include_lib`. Headers determine record positions
  and defaults. Put project headers in the normal Erlang include directory.
- Elixir references contain module components and the function name, such as
  `["MyApp", "Orders", "copy"]`. Constructor references name structs. Mapped
  fields are passed to `struct!`, preserving defaults on other fields. A
  lowercase singleton reference such as `["empty"]` represents an atom.
- Gleam references contain module path components and a function or capitalized
  type/constructor name. Generated typed constructor helpers use mapped labels,
  preserving the native constructor's field order. Codec hooks can represent
  opaque types through their public functions.
- Method bindings call the bound handle's module with the receiver first.
  Constructor bindings omit `Unit` inputs; a `Unit` result ignores the native
  return value after executing the call.
- Native BEAM handles use a pid, reference or port. Generated actors also
  have stable mailbox addresses: their identity survives replacement of the
  worker process, and children of the same supervisor have distinct identities.
- Factories return PropEr generators, `StreamData.t(a)` or `qcheck.Generator(a)`.
  Child generators produce native bound values. Every generated value and shrink
  crosses the checked schema before refinements filter it. Invalid values fail.
  Finite domains are enumerated without invoking their factories.
- Optional factory scaffolds live in Erlang `test/`, Elixir `test/support/`, or
  Gleam `test/`. Gleam factories can import the application's types. Generated
  Erlang test helpers for Gleam live in the local `test-support/` development
  package, keeping property frameworks out of production exports.

## Uninhabited type parameters

A factory for a type such as `Phantom Empty` may ignore its child generator: it
must not fail merely because `Empty` has no values. Demanding a value from that
child fails generation, so it can never make a property pass. Finite containers
such as `List Empty` are still enumerated.

## Parameter names

Generated code names an adapter's parameters as its signature does.
ref:DEC-generated-parameter-names

```lawspec
unit bindings.names
add :: (a :: Int32) -> (b :: Int32) -> Int32
plus :: Int32 -> Int32 -> Int32
end unit
```

| Target | `add` | `plus` |
| --- | --- | --- |
| Java, Groovy | `add(int a, int b)` | `plus(int int32_1, int int32_2)` |
| Kotlin | `fun add(a: kotlin.Int, b: kotlin.Int)` | `fun plus(int32_1: kotlin.Int, int32_2: kotlin.Int)` |
| Scala | `def add(a: scala.Int, b: scala.Int)` | `def plus(int32_1: scala.Int, int32_2: scala.Int)` |
| Clojure | `[a b]` | `[int32-1 int32-2]` |
| Python | `def add(a: int, b: int)` | `def plus(int32_1: int, int32_2: int)` |
| JavaScript | `function add(a, b)` | `function plus(int32_1, int32_2)` |
| TypeScript | `function add(a: number, b: number)` | `function plus(int32_1: number, int32_2: number)` |
| Go | `func Add(a int32, b int32)` | `func Plus(int32_1 int32, int32_2 int32)` |
| Rust | `pub fn add(a: i32, b: i32)` | `pub fn plus(int32_1: i32, int32_2: i32)` |
| Swift | `func add(_ a: Int32, _ b: Int32)` | `func plus(_ int32_1: Int32, _ int32_2: Int32)` |
| C# | `Add(int a, int b)` | `Plus(int int32_1, int int32_2)` |
| F# | `let add (a: int) (b: int)` | `let plus (int32_1: int) (int32_2: int)` |
| Haskell | `add _a _b =` | `plus _int32_1 _int32_2 =` |
| Elixir | `def add(_a, _b)` | `def plus(_int32_1, _int32_2)` |
| Gleam | `pub fn add(_a: Int, _b: Int)` | `pub fn plus(_int32_1: Int, _int32_2: Int)` |
| Erlang | `add(_A, _B)` | `plus(_Int32_1, _Int32_2)` |
| Prolog | `ls_add(_A, _B, _)` | `ls_plus(_Int32_1, _Int32_2, _)` |

- **A declared name** is cased as the target cases a value: `order_id` or
  `orderId` in the spec is `order_id` in Python and Rust, `orderId` in Java,
  `order-id` in Clojure and `OrderId` as an Erlang or Prolog variable. A
  reserved word is escaped the target's way (`class_` in Java, `r#type` in
  Rust, `` `class` `` in Swift).
- **A parameter without a name** is named after its type and numbered from 1
  among the unnamed parameters of that type: `int32_1`, `int32_2`. A compound
  type gives its head: `List Text` is `list_1`, `Maybe Order` is `maybe_1`, a
  record `Order` is `order_1` (written here in snake_case). An anonymous
  record is `record_1`, a function `function_1`, a type variable `value_1`
  and `BigUInt` `whole_1`.
- **The number is joined as the target joins a word**: `order_line_1` and
  `text_1` in snake_case, `order-line-1` in Clojure, `orderLine1` and `text1`
  in camelCase (`OrderLine1` as an Erlang or Prolog variable). camelCase
  writes an underscore only to keep two numbers apart, as Google's Java guide
  does: `int32_1`, `float64_2`. A sole parameter keeps its number, so a
  second parameter of the type never renames the first.
- **Names stay distinct.** Two names that case alike, or a name the generated
  signature already uses (a handler parameter, for example), are numbered
  from 2 the same way, in parameter order: `orderId`, `orderId2`.
- **A stub that reads nothing** marks its parameters as unused where the
  target would warn: a leading underscore in Haskell, Elixir, Gleam, Erlang
  and Prolog. Remove it when you use the parameter.
- A definition's parameters (`function total (a :: Int32) …`) and an
  ability's operations are named the same way, in interfaces and in
  production handler stubs. A result's name stays in the spec.

Text about an adapter's laws uses the spec's spelling of these names: an input
a claims block leaves out is reported as `current = Cancelled`, or
`state_1 = Cancelled` when the signature names nothing.

Names never affect what an adapter must implement. An existing adapter is not
rewritten, and neither naming a parameter nor renaming one reports an adapter
update: the stub an adapter is compared with is written with positional names
(`value0`, `value1`). A parameter's name is not part of a declaration's
semantic hash.

The abilities of the built-in units (`lawspec.time`, `lawspec.crypto` and the
others with default handlers) name their parameters in their signatures, so
their interfaces read `sleep(duration)`, `sign(signingKey, message)` and
`writeBytes(path, contents)`. The code generated around an ability, such as
spec handlers, recordings and binding bridges, uses the same names; a name
the generated code needs for itself is numbered from 2 (`state2`). What stays
numbered by position is the code nobody reads as an interface: the evaluator
behind a checked definition (`input0`), codec locals (`codec0`, `field0`)
and generic type parameters (`T0`). A JavaScript or TypeScript data class's
constructor names its parameters after its fields.

## Ownership

Generated bridges and runtimes are generated source. Framework helpers are
generated test code (Go test files share their package's directory).
Application models, hooks and factories are user-owned; the manifest never
claims them.

- An existing adapter at a new bridge's path blocks generation until you move
  it aside.
- Removing bindings keeps the former bridge as a user-owned adapter and reports
  the required adapter signature.
- Unchanged generation is a no-op, including after a profile or format change.
- Changing the layout moves generated files but not application files.

See [ownership and regeneration](../explanation/ownership-and-regeneration.md).


---
id: lawspec.how-to.bind-native-types
kind: how-to
title: Bind native types and functions
---
# Bind native types and functions

By default, LawSpec generates its own native types for your data declarations,
and you implement adapters against them. If your application already has its
own domain model, native bindings connect LawSpec's types and adapters to it
directly. The compiler then generates checked conversions between the two.

Keep the module defining bound application types independent of generated modules
that import those types. In JavaScript, importing a generated checked definition
back into that module can create an initialization cycle; put application calls
in a separate module.

Bindings change only the native representation. Arithmetic, equality,
definitions and refinements keep their LawSpec meaning.

This guide covers type and function bindings. For conversion hooks and custom
generators, see [custom codecs and generators](library.md#custom-codecs-and-generators).
The implementation contract for each target is in the
[native bindings reference](../reference/native-bindings.md).

## Start from the bundled example

The quickest way to see bindings working is the payment project:

```sh
npx lawspec examples --example payments --target python
```

It exports an application with its own names for the specification's types
(`Price` for `Money`, `CurrencyCode.Dollars` for `Currency.USD`) and a
`lawspec.edn` that binds them. See
[Generate example artifacts](https://goforge.dev/lawspec/how-to/generate-example-artifacts.html#export-the-runnable-payment-project).

## Add bindings to a target

Bindings belong to a target, under `native-bindings`:

```edn
{
  :manifest-version 1
  :component {
    :name "payments"
    :version "0.1.0"
  }
  :language-profile "1.0-rc.2"
  :sources ["laws"]
  :targets [
    {
      :language :python
      :root "."
      :native-bindings {
        :types []
        :functions []
        :generators []
      }
    }
  ]
}
```

`native-bindings` accepts `types`, `functions`, `generators`, `rust-crate` (Rust
only), `go-imports` (Go only) and `erlang-includes` (Erlang only). Unknown fields are errors, so a misspelled
option can never be silently ignored.

## Name LawSpec declarations

Bindings refer to LawSpec declarations by their resolved identities:

- a data type: `<unit>::type::<Name>`, for example `example.payments::type::Money`;
- an adapter: `<unit>::<name>`, for example `example.payments::addFee`;
- constructors and fields: by their names in the declaration.

## Name native symbols

A native reference is an array of identifier segments, never a code snippet.
What the segments mean depends on the target:

| Target | Reference | Example |
| --- | --- | --- |
| Rust | A path, starting with `crate` for the application library | `["crate", "domain", "Price"]` |
| Python | Module components, then the exported class or function | `["payments_domain", "Price"]` |
| JavaScript, TypeScript | Module path segments, then the exported name | `["payments_domain", "Price"]` |
| Java | A fully qualified type, constructor or static method name | `["domain", "PaymentsDomain", "Price"]` |
| Kotlin | A fully qualified class, object or function name | `["domain", "PaymentsDomain", "Price"]` |
| Go | One package-local identifier, or an import alias and an exported identifier | `["Price"]`, `["domain", "Price"]` |
| Haskell | Module components, then the type, constructor or function | `["PaymentsDomain", "Price"]` |
| F# | A qualified application type, union case or function | `["PaymentsDomain", "Price"]` |
| Swift | A qualified application type, enum case or static function | `["PaymentsDomain", "Price", "price"]` |
| Erlang | Module and type or function; a constructor uses one atom or record name | `["payments_domain", "apply_fee"]`, `["price"]` |
| Elixir | Module components, then the function when calling one | `["PaymentsDomain", "Price"]`, `["PaymentsDomain", "apply_fee"]` |
| Gleam | Module path segments, then the type, constructor or function | `["payments_domain", "Price"]` |

JavaScript and TypeScript source references resolve from the source directory,
and generator references from the test directory.

## Bind a type

Map the type, every constructor and every field:

```edn
{
  :type "example.payments::type::Money"
  :native ["payments_domain" "Price"]
  :constructors [
    {
      :constructor "Money"
      :native ["payments_domain" "Price"]
      :style "record"
      :fields [
        {
          :field "amount"
          :native "major"
        }
        {
          :field "currency"
          :native "unit"
        }
      ]
    }
  ]
}
```

Each constructor has a `style`:

- `record`: the type's only constructor, a product with fields;
- `variant`: one alternative of a sum, with its payload fields;
- `unit`: an alternative with no fields, such as an enum constant.

A sum maps each alternative:

```edn
{
  :type "example.payments::type::Payment"
  :native ["payments_domain" "PaymentStatus"]
  :constructors [
    {
      :constructor "Paid"
      :native ["payments_domain" "Settled"]
      :style "variant"
      :fields [
        {
          :field "value"
          :native "price"
        }
      ]
    }
    {
      :constructor "Declined"
      :native ["payments_domain" "Rejected"]
      :style "variant"
      :fields [
        {
          :field "reason"
          :native "explanation"
        }
      ]
    }
  ]
}
```

And an enumeration maps each constant with `unit`:

```edn
{
  :type "example.payments::type::Currency"
  :native ["payments_domain" "CurrencyCode"]
  :constructors [
    {
      :constructor "USD"
      :native ["payments_domain" "CurrencyCode" "Dollars"]
      :style "unit"
    }
    {
      :constructor "EUR"
      :native ["payments_domain" "CurrencyCode" "Euros"]
      :style "unit"
    }
    {
      :constructor "GBP"
      :native ["payments_domain" "CurrencyCode" "Pounds"]
      :style "unit"
    }
  ]
}
```

### How each target builds and reads values

The generated bridge constructs and inspects your types with the target's
ordinary conventions:

| Target | Constructing | Reading fields |
| --- | --- | --- |
| Python | Keyword arguments, so keyword-only dataclasses and reordered fields work. Classes are checked by exact identity. | Attributes |
| JavaScript, TypeScript | One object whose keys are the mapped field names; unit classes take no arguments. | Own properties |
| Java | Constructor arguments in LawSpec field order. `unit` refers to an enum constant. An empty record uses `record` or `variant`. | Accessor methods |
| Kotlin | Constructor arguments in LawSpec field order. `unit` refers to an enum constant or singleton object, compared by identity. | Properties |
| Go | Keyed struct literals; mapped fields must be exported. `unit` refers to a constant. | Fields |
| Haskell | Record construction and matching by field name, independent of declaration order. | Record selectors |
| Rust | Struct and enum-variant literals with named fields; `unit` refers to a unit variant. Recursive fields need the same indirection as the generated type. | Fields |

When your type does not fit these conventions, for example because it has
private storage, a different recursive layout or a smart constructor, use a
[codec hook](custom-codecs-and-generators.md#convert-with-codec-hooks) instead.

Bindings compose through type parameters, recursion, `List`, `Maybe`,
`Either`, `Nullable` and `Optional`. Types you do not bind keep their generated
representation.

## Bind an adapter to an existing function

```edn
{
  :functions [
    {
      :declaration "example.payments::addFee"
      :native ["payments_domain" "apply_fee"]
    }
    {
      :declaration "example.payments::roundTrip"
      :native ["payments_domain" "restore"]
    }
    {
      :declaration "example.payments::archive"
      :native ["payments_domain" "store"]
    }
  ]
}
```

A unit with function bindings must currently map every adapter it declares.
The compiler-generated bridge validates the inputs, converts them, calls your
function, converts the result and validates it.

| Targets | Bridge location |
| --- | --- |
| Erlang, Elixir, Gleam | `lawspec_native_bindings.erl` in the source directory |
| Rust, Python, JavaScript, TypeScript, Java, Kotlin, Go, Haskell | The unit's adapter file |

## Rust: name the application crate

Rust tests must use your library's own types, not a second compiled copy.
Name the library crate with `rust-crate`:

```edn
{
  :native-bindings {
    :rust-crate "lawspec_example"
    :types []
    :functions []
  }
}
```

## Go: bind types from other packages

Declare import paths separately, then refer to their exported names through the
alias:

```edn
{
  :go-imports [
    {
      :alias "domain"
      :path "example.org/application/domain"
    }
  ]
  :functions [
    {
      :declaration "example::echo"
      :native ["domain" "Echo"]
    }
  ]
}
```

One alias can qualify types, constructors, functions, generator factories, failure types and handler factories.
Each generated file imports only what it uses. The compiler renames aliases
internally, so an alias such as `rapid` cannot shadow a framework import.
Duplicate aliases or paths, traversal segments and undeclared aliases are
errors.

If a generated type would have the same name as one of your package's types,
the compiler gives the generated one a `Canonical` prefix (`CanonicalBox`, or
`Canonical1Box` if that is also taken). LawSpec identities do not change.

## Check the bindings

```sh
npx lawspec check
npx lawspec generate --dry-run
```

`check` resolves every binding against the typed declarations and reports
unknown types, constructors or fields, duplicate or incomplete mappings,
incompatible type arities and malformed references. `generate` additionally
checks that the target supports what you asked for.

`lawspec evidence` lists each type binding as `RUNTIME CHECKED`, because values
cross it through checked conversions, and each native function as
`ASSUMED / EXTERNAL`.

## Adopt bindings in an existing project

### Erlang, Elixir and Gleam

Implement the mapped functions in your application modules, add the bindings,
and run `lawspec generate`. LawSpec creates a separate native bridge and keeps
existing user adapters. Application types, generator factories and build files
remain yours. Generation refuses to overwrite an unowned file at the bridge's
path or an edited generated bridge.

Removing the bindings removes the unedited native bridge and any unused binding
helpers. LawSpec creates missing adapter stubs and preserves existing adapters.
Implement the adapters for the specification's types before running the tests.
An edited generated bridge must be reviewed before generation can remove it.

### Targets that use the adapter file as the bridge

When a unit gains function bindings, LawSpec refuses to overwrite your existing
adapter, even if it is still the untouched stub. To adopt bindings:

1. Move the implementation into the application module the bindings name.
2. Move the old adapter file out of the way, outside the bridge's path.
3. Run `lawspec generate`.

Do not edit `.lawspec/generated.json` to make your code look generated.

If you later remove the bindings, LawSpec keeps the former bridge as a
user-owned adapter and reports the adapter signature you now need to
implement. Review it and implement the adapter before running the tests.

For targets supporting custom roots, changing `sourceDir` or `testDir` moves
generated files. Your application models, hooks and factories stay where they
are. Gleam uses `src` and `test`, with generated Erlang test helpers in
`test-support/src`.

See [ownership and regeneration](../explanation/ownership-and-regeneration.md).


---
id: lawspec.how-to.custom-codecs-and-generators
kind: how-to
title: Write custom codecs and generators
---
# Write custom codecs and generators

This guide covers two extensions to [native type bindings](library.md#bind-native-types-and-functions):
codec hooks, for application types that constructor and field mappings cannot
describe, and generator bindings, which make the generated tests draw values
from your own property-testing generators.

## Convert with codec hooks

A type binding can name a pair of conversion functions instead of mapping
constructors and fields:

```json
{
  "type": "native.codecs::type::Parcel",
  "native": ["crate", "domain", "Parcel"],
  "codec": {
    "toNative": ["crate", "codecs", "to_parcel"],
    "fromNative": ["crate", "codecs", "from_parcel"]
  }
}
```

Both directions are required, and a binding cannot have both `codec` and
`constructors`. Hooks are ordinary application functions with no testing
dependency.

`toNative` receives a value of the generated LawSpec type and returns your
type; `fromNative` does the reverse. For each type parameter, a hook also
receives a converter function for that parameter, in the same direction. Use it
to convert the payload: the hook cannot convert payloads itself.

The generated bridge still validates every value against the LawSpec type, so a
hook cannot bypass range checks or constructor contracts. Errors from a hook
are reported with the type identity and the conversion direction.

### Hook signatures by target

| Target | `toNative` for `Parcel a` | Failure |
| --- | --- | --- |
| Rust | `fn to_parcel<T, N>(value: Parcel<T>, convert: &dyn Fn(T) -> N) -> lawspec_runtime::Result<domain::Parcel<N>>` | Return an error |
| Haskell | `toParcel :: Data.Parcel a -> (a -> b) -> Either String (Domain.Parcel b)` | Return `Left` |
| Python | `to_parcel(value, convert_item)`, receiving the generated class (for example `Parcel`) | Raise an exception |
| JavaScript, TypeScript | `to_parcel(value, convertItem)`, receiving the generated class | Throw |
| Java | `to_parcel(Parcel<A> value, Function<A, B> convert)` returning your `Parcel<B>` | Throw |
| Kotlin | `to_parcel(value: Parcel<A>, convert: (A) -> B): Parcel<B>` | Throw |
| Scala | `to_parcel(value: Parcel[A], convert: A => B): Parcel[B]` | Throw |
| Go | A function of the value and one converter per type parameter, returning `(value, error)` | Return an error |
| Erlang | `to_parcel(Value, Convert)` returns the bound native value | Raise an exception |
| Elixir | `to_parcel(value, convert)` returns the bound native value | Raise an exception |
| Gleam | `fn to_parcel(value: data.Parcel(a), convert: fn(a) -> b) -> domain.Parcel(b)` | Panic |

`fromNative` has the mirror-image signature. In Haskell, Java, Kotlin, Scala and Go the
generated type's payloads are opaque checked values; only the supplied
converters can turn them into your payload type. Python, JavaScript and
TypeScript pass native payloads to the converters.

Go hooks that name generated types must live in the generated types' package.
Placing them in a package that imports the generated package would create an
import cycle, because the generated bridge imports the hooks.

## Use your own generators

A generator binding tells the generated tests to draw values of a type from a
factory you write, using your target's property-testing library:

```json
"generators": [
  {"type": "example.payments::type::Money", "factory": ["lawspec_generators", "prices"]}
]
```

The factory returns the framework's generator for the bound native type. A
factory for a type with parameters receives one generator per type argument.

| Target | Factory returns | Children | Typical test location |
| --- | --- | --- | --- |
| Rust | A Proptest strategy | One boxed strategy per type argument | `tests/support/lawspec_generators.rs` |
| Python | A Hypothesis `SearchStrategy` | One strategy per type argument | `tests/lawspec_generators.py` |
| JavaScript, TypeScript | A fast-check `Arbitrary` | One arbitrary per type argument | `test/lawspec_generators.mjs` |
| Java | A JetCheck `Generator` from a static method | One `Generator<T>` per type argument | `src/test/java/domain/PaymentGenerators.java` |
| Kotlin | A Kotest `Arb` | One `Arb<T>` per type argument | `src/test/kotlin/domain/PaymentGenerators.kt` |
| Scala | A `lawspec.testing.Arb`, which ScalaCheck runs | One `Arb[T]` per type argument | `src/test/scala/domain/PaymentGenerators.scala` |
| Go | A Rapid `*rapid.Generator` from a package-local function | One generator per type argument | `example/payments/native_generators_test.go` |
| Haskell | A Hedgehog `Gen` | One `Gen` per type argument | `test/PaymentGenerators.hs` |
| Erlang | A PropEr generator | One native generator per type argument | `test/application_generators.erl` |
| Elixir | `StreamData.t(a)` | One `StreamData.t(a)` per type argument | `test/support/application_generators.ex` |
| Gleam | `qcheck.Generator(a)` | One `qcheck.Generator(a)` per type argument | `test/application_generators.gleam` |
| F#, C# | An FsCheck `Arbitrary<T>` from a function or static method of no arguments | None: types with parameters are not bound | `tests/Native/PaymentGenerators.fs`, `tests/Native/PaymentGenerators.cs` |

Factories are test code: they belong in the test directory and are yours.

Gleam factories may import your application types from `src/`. The generated
Erlang test helpers use a separate `test-support/` development package so that
Gleam production exports contain no property framework or generator registry.

### What the tests do with your generator

- The tests compose and map your generator directly, so its shrinker is kept.
  Build factories with your framework's combinators to keep shrinking good.
- Every sample and every shrink candidate passes through the checked
  conversion. An invalid value fails the test with context; it is not
  silently discarded.
- Refinements on quantified inputs still filter your distribution.
- Explicit examples, boundary cases and finite-domain enumeration still run
  independently. A small finite domain is enumerated without calling your
  factory at all.
- If your generator cannot produce a valid value, the test fails. It never
  falls back to a built-in value, and never passes with no cases.

A factory may ignore a parameter whose type has no values, as in
`Phantom Empty`. Asking that parameter's generator for a value fails the test.

## Scaffold a factory

Set `"stub": true` to have LawSpec create the factory file for you:

```json
"generators": [
  {"type": "List", "factory": ["application_generators", "lists"], "stub": true}
]
```

The scaffold is user-owned. Its body fails until you implement it. Factories
that share a module share one file. Existing files are never overwritten; if
the required signature changes, `generate` reports it as an adapter update.
Changing the test layout creates a new scaffold at the new path and leaves the
old file in place: move your implementation across.

| Target | Reference | Creates | Initial body |
| --- | --- | --- | --- |
| Python | `["application_generators", "lists"]` | `tests/application_generators.py`, function `lists(argument_0)` | raises `NotImplementedError` |
| Rust | `["factories", "collections", "values"]` | `tests/support/factories.rs`, public module `collections`, function `values` returning `BoxedStrategy<Native>` | `unimplemented!` |
| JavaScript, TypeScript | `["factories", "collections", "lists"]` | `test/factories/collections.mjs` (or `.ts`) | throws |
| Java | `["application", "Factories", "prices"]` | `application/Factories.java` in the test directory; public static method | throws `UnsupportedOperationException` |
| Kotlin | `["application", "Factories", "prices"]` | `application/Factories.kt` in the test directory; function in object `Factories` | throws `NotImplementedError` |
| Scala | `["application", "Factories", "prices"]` | `application/Factories.scala` in the test directory; method of object `Factories` | throws `NotImplementedError` |
| Go | a package-local name | `native_generators_test.go` beside each consuming unit's tests | panics |
| Haskell | `["Application", "Generators", "lists"]` | `Application/Generators.hs` in the test directory, for example `lists :: H.Gen a0 -> H.Gen [a0]` | calls `error` |
| Erlang | `["application_generators", "lists"]` | `test/application_generators.erl`, exported PropEr factory | calls `erlang:error` |
| Elixir | `["Application", "Generators", "lists"]` | `test/support/application_generators.ex`, typed StreamData factory | raises |
| Gleam | `["application_generators", "lists"]` | `test/application_generators.gleam`, typed qcheck factory | panics |

Target-specific rules:

- **Rust.** Type parameters have `Debug + 'static` bounds. `crate` and `self`
  prefixes refer to the integration-test support module. Explicit `crate` or
  `self` references keep importing the local module even with `stub: false`.
  The scaffold root cannot be the `rustCrate` name, a framework import or a
  generated support name.
- **Java, Kotlin and Scala.** The class or object must be in a named package, and must
  not collide with generated or application classes or with inherited
  `Object`/`Any` methods.
- **Go.** Imported factories are never scaffolded. A scaffolded factory needs a
  quantified use, which determines the package it belongs in.
- **Python and Haskell.** Use a dedicated test module. Names that collide with
  generated support, application modules or another scaffold are rejected.

Omitting `stub`, or setting it to `false`, only imports the factory.


---
id: lawspec.how-to.embed-a-generated-model
kind: how-to
title: Embed a generated model
---
# Embed a generated model

A spec handler with state is a reference model: each operation runs a checked
definition over the handler's state and keeps the next state. On every target
(Rust, Go, Java, Kotlin, Python, JavaScript, TypeScript, Haskell, Erlang,
Elixir and Gleam) the generated code is fast enough to serve as a runtime, so an application (a test
double, a simulator, a digital twin) can construct the handler itself and call
its operations directly, outside any law.

## What runs typed

A checked definition runs as typed native code when every value it touches has
a typed form, it calls only other typed definitions, and it has no runtime
contract or workflow policy. The typed forms are:

| LawSpec | Rust | Go | Java and Kotlin |
| --- | --- | --- | --- |
| `Bool`, `Unit` | `bool`, `()` | `bool`, `lsfUnit` | `boolean`, `LawSpecFast.Unit` |
| `Int8` to `UInt32` | `i8` to `u32` | `int8` to `uint32` | `long` |
| `UInt64` | `u64` | `uint64` | (untyped) |
| `Integer` | an `i64` until it outgrows it | the same | `BigInteger` |
| `Text`, `Bytes` | shared `Arc<str>`, `Arc<[u8]>` | `string` | `String`, `LawSpecFast.Bytes` |
| `List a` | a persistent cons list | the same | the same |
| `KeyVal k v`, `Set a` | a persistent AVL tree in the portable order | the same | the same |
| data | an enum behind an `Arc` | a pointer to a struct, or an interface | a class per constructor |

| LawSpec | Python | JavaScript and TypeScript | Haskell |
| --- | --- | --- | --- |
| `Bool`, `Unit` | `bool`, `None` | `boolean`, `null` | `Bool`, `()` |
| `Int8` to `UInt32` | `int` | `number` | `Int8` to `Word32` |
| `Int64`, `UInt64` | `int` | a `number` until it outgrows a safe integer, then a `bigint` | `Int64`, `Word64` |
| `Integer` | `int` | the same | `Integer` |
| `Text`, `Bytes` | `str`, `bytes` | `string`, `Uint8Array` | `Text`, `ByteString` |
| `Maybe`, `Either` | `()` or `(x,)`, `(0, l)` or `(1, r)` | `null` or a `Present`, a `Side` | strict `Opt`, `Alt` |
| `List a` | a persistent cons list of tuples | a persistent cons list | a strict list that knows its length |
| `KeyVal k v`, `Set a` | a persistent AVL tree of tuples | a persistent AVL tree | `Data.Map.Strict`, `Data.Set` |
| data | a tuple, after the constructor's rank when there are several | a class per constructor, typed in TypeScript | a strict data type, constructors in the portable order |

| LawSpec | Erlang | Elixir | Gleam |
| --- | --- | --- | --- |
| `Bool`, `Unit` | `boolean()`, `ok` | `boolean()`, `:ok` | `Bool`, `Nil` |
| integers | `integer()`, checked where bounded | the same | `Int`, the same |
| `Text`, `Bytes` | UTF-8 `binary()`, `binary()` | the same | `String`, `BitArray` |
| `Maybe`, `Either` | `nothing` or `{just, X}`, `{left, L}` or `{right, R}` | the same | `Option`, `Result` |
| `List a` | a list | a list | a `List` |
| `KeyVal k v`, `Set a` | a map, a version 2 `sets` set | the same | the same |
| data | the native tuple | the native struct | the native custom type |

In Python, Python's own tuple equality and order are LawSpec's, so maps of
such keys compare keys with `==` and `<` directly; in Haskell, the derived
`Eq` and `Ord` of the typed data types are. Typed Haskell definitions run in
`IO`, every binding strict, so each value is evaluated where it is written.
On the BEAM, typed code is one Erlang module, `lawspec_typed`, over each
language's own data, so only `KeyVal` and `Set` values convert at its
boundary; their entries and items come out in the portable order (Erlang's
term order where it is the same, a generated comparison where it is not).

Anything else runs as before, on the dynamic values every target shares. Both
paths give the same results; the acceptance suites run every target's laws and
mutants over them.

On Python, JavaScript, TypeScript, Haskell, Erlang, Elixir and Gleam, typed
code carries the handler context: a definition that performs another ability's operation (a client
handler's clause that calls the broker, say) takes the law's symbols, finds
the operation's handler there, and calls it with native values, exactly as
the dynamic code does. Such a definition, and a handler whose clauses are
such definitions, runs typed too. On Rust, Go, Java and Kotlin a definition
that performs an operation other than `raise` stays dynamic.

Because a list shares its tail and a map update copies only the path to its
key, an operation costs what it changes, not the size of the state: appending
a record to a log of a million records allocates the record and one cell. A
handler's state is never copied between operations (on the BEAM it stays in
the handler's cell process, and each operation runs there), and memory grows with
what the state retains. Imported definitions that are the same up to their
names share one function (on Go, one in each package that holds them), so a
package's model is generated once, however many units import it.
ref:DEC-typed-native-definitions

## Construct a handler and call it

Take a handler with state, such as a counter:

```lawspec
unit example.tallies

ability Counter is
bump :: Int64 -> Int64
end ability

handler tally for Counter with state total :: Int64 start 0 is
operation bump n is
~total := (if n >= 0 && n <= 1000000 && total <= 1000000 - n then prelude.Int64
(total + n) else total end if); total
end operation
end handler
end unit
```

Each target generates an entry point that makes the handler with its start
state, apart from any law:

| Target | Entry point |
| --- | --- |
| Rust | `lawspec_abilities::example_tallies::Tally::start()` |
| Go | `tallies.StartTally()` |
| Java | `new lawspec.abilities.example.Tallies.Tally()` |
| Kotlin | `lawspec.abilities.example.Tallies.Tally()` |
| Python | `lawspec_abilities.example.tallies.Tally()` |
| JavaScript, TypeScript | `new Tally()` from `lawspec_abilities/example/tallies` |
| Haskell | `LawSpecHandlers.Example.Tallies.tally symbols`, with `symbols <- LawSpecRuntime.newSymbolContext` |
| Erlang, Elixir, Gleam | `tally(Context)` inside `with_context` (see [handlers](../reference/language/handlers.md#erlang-elixir-and-gleam)) |

The handler implements the ability's interface (the trait in Rust), so the
application calls its operations with its own native types:

```rust
use lawspec_example::lawspec_abilities::example_tallies::{Counter, Tally};

let counter = Tally::start();
assert_eq!(counter.bump(2), 2);
assert_eq!(counter.bump(3), 5);
```

```python
from lawspec_abilities.example.tallies import Tally

counter = Tally()
assert counter.bump(2) == 2
assert counter.bump(3) == 5
```

```typescript
import { Tally } from './lawspec_abilities/example/tallies.js';

const counter = new Tally();
counter.bump(2n); // 2n
counter.bump(3n); // 5n
```

```haskell
import qualified LawSpecRuntime as LS
import qualified LawSpecHandlers.Example.Tallies as Handlers
import LawSpecAbilities.Example.Tallies (bump)

main :: IO ()
main = do
  symbols <- LS.newSymbolContext
  counter <- Handlers.tally symbols
  _ <- bump counter 2
  bump counter 3 >>= print -- 5
```

A Haskell handler of several abilities, or one with typed state, can be made
in two steps, its state and then a record per ability over it: `state <-
Handlers.clusterState symbols`, then `Handlers.clusterBroker symbols state`
and `Handlers.clusterAdmin symbols state` share one state.

Arguments and results convert directly between the native types and the
typed forms, without the dynamic values the laws use (when `lawspec.edn`
binds native types, they cross through the handler schema instead). The
handler is safe to share between threads on Rust, Go, Java, Kotlin, Python and
Haskell, and between processes on the BEAM: its operations apply one at a time, each to the state the previous
one left, and on Haskell an operation that fails leaves the state as it was.

A handler whose clauses perform another ability's operations finds that
ability's handler in its context, so make it with a context that holds one: a
Python `KafkaProducer(symbols)` with `ls.install_handlers(symbols,
{"lawtwin.kafka::ability::Broker": Cluster()})` first, and likewise
`ls.installHandlers(symbols, {...})` on JavaScript and TypeScript and
`LS.installHandlers symbols [LS.installed key broker]` on Haskell.

## Take a failure as a value

An operation that `fails with E` raises its failure as the laws see it: a
panic in Rust and Go, an exception elsewhere. For an application, each such
operation has a second form that returns the failure instead, in the native
types:

| Target | `produceRequest` that fails with `KafkaError` |
| --- | --- |
| Rust | `try_produceRequest(...) -> Result<i64, KafkaError>` |
| Go | `TryProduceRequest(...) (int64, error)`, the error a `*LawSpecRaised[KafkaError]` (`errors.As`) |
| Java, Kotlin | `tryProduceRequest(...)`, a `LawSpecFast.Outcome<Long, KafkaError>`: `failed()`, `value()`, `failure()` |
| Python | `try_produceRequest(...)`, `Right` of the result or `Left` of the failure |
| JavaScript, TypeScript | `tryProduceRequest(...)`, `Right` of the result or `Left` of the failure |
| Haskell | `tryProduceRequest broker ...`, in the ability's handlers module: `IO (Either KafkaError Int64)` for any handler |
| Erlang, Elixir | `broker_try_produce_request(Broker, ...)` (Elixir: `Broker.try_produce_request(broker, ...)`): `{ok, Offset}` or `{error, KafkaError}`, for any handler |
| Gleam | `broker_try_produce_request(broker, ...)`: a `Result(Int, data.KafkaError)`, for any handler |

A failing operation leaves the state as it was. Rust dynamic handlers also
provide `start`, `try_` operations and native `state` / `set_state` methods.
They evaluate through the checked dynamic runtime and validate restored states
against their declared schema. The typed snapshot methods apply to typed
handlers; dynamic snapshots copy the state.

## Read and replace the state

A handler with state gives its state in its native types, as a snapshot to
show or keep, and takes one back, to force the state, reset it or restore an
earlier snapshot:

| Target | Read | Replace | Typed, shared rather than copied |
| --- | --- | --- | --- |
| Rust | `state()` | `set_state(s)` | `typed_state()`, `set_typed_state(s)` |
| Go | `State()` | `SetState(s)` | `TypedState()`, `SetTypedState(s)` |
| Java, Kotlin | `state()` | `setState(s)` | `typedState()`, `setTypedState(s)` |
| Python | `state()` | `set_state(s)` | `typed_state()`, `set_typed_state(s)` |
| JavaScript, TypeScript | `state()` | `setState(s)` | `typedState()`, `setTypedState(s)` |
| Haskell | `clusterSnapshot state` | `clusterRestore state s` | `readMVar state`, `swapMVar state s` |
| Erlang, Elixir, Gleam | `cluster_state(Broker)` | `cluster_set_state(Broker, S)` | `cluster_typed_state(Broker)`, `cluster_set_typed_state(Broker, S)` |

The native forms convert the whole state, so they cost what it holds; the
typed ones cost nothing, since a typed state is never changed in place. On
the BEAM the typed ones convert nothing but copy the state, since processes
share no heap; in Gleam the typed state is the opaque `ClusterTypedState`. The
typed state's type is the generated one (Go's is unexported, so an
application keeps it without naming it).

## Names and builds

The typed functions a handler's clauses call, and its start, are named from
the definitions and the handler: a function's name is its definition's name,
with a suffix only when two would otherwise share one, so an unrelated edit
of the contract does not rename them. (Python, Go, JavaScript, TypeScript,
Haskell, Swift, Rust (in snake case), F#, C# and the BEAM targets have these
names from 0.30; the other targets keep a digest suffix until their
readable-output release.) Generation depends only on the program: the compiler's cache
is kept per compiler build, so a compiler rebuilt in place never reuses what
another build made (`lawspec-dev bench kafka --deterministic` generates the
model in process, with a cold and a warm cache, without one, and by the
native compiler, and requires the same bytes). The generated Rust crate,
Haskell package and `lawspec_typed` module build without warnings, so a project that depends on them
sees none.

## Laws and applications share the handler

The handler a law uses is the same type, made with the law's context
(`Tally::new(&ctx)` in Rust, `NewTally(symbols)` in Go, the one-argument
constructor on the JVM), so what the laws check is what the application runs.

## Measure it

`lawspec-dev bench kafka`, in the LawSpec repository, generates LawTwin's
Kafka reference model for every target and drives its `cluster` handler: a
million produces over 100 partitions, a consumer group of ten members fetching
and committing with a rebalance, and transactions. It prints each phase's
throughput and the memory the state retains; `--scale N` runs a smaller
workload, and naming targets runs only those. The drivers in
`bench/kafka/<target>/` are worked examples of embedding a handler on each
target.
