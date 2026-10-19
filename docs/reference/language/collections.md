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
        when Nothing then countWords rest (prelude.put w 1 counts)
        when Just n then countWords rest (prelude.put w ((n + 1) :: Integer)
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
      prelude.lookup k (prelude.put k w (prelude.put k v m)) = Just w end for all
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
- lists element by element, a prefix first; `Nothing` before `Just`;
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
