---
id: lawspec.reference.language.collections
kind: reference
title: Collections
---
# Collections

Besides `List`, LawSpec has five built-in collections:

| Type | Holds |
| --- | --- |
| `Set a` | distinct elements, in the portable order |
| `KeyVal k v` | entries with distinct keys, in the portable order of the keys |
| `Queue a` | items, first in first out |
| `Stack a` | items, last in first out |
| `Deque a` | items, added and removed at either end |

`Entry k v` is a key/value pair, built with `Entry key value`. `Ordering` has
the constructors `Less`, `Equal` and `Greater`.

```lawspec
unit guide.collections

dedupe :: List Int32 -> Set Int32
wordCounts :: List Text -> KeyVal Text BigInt

definition countWords (words :: List Text) (counts :: KeyVal Text BigInt) :: KeyVal Text BigInt is
  match words with
  | Nil -> counts
  | Cons w rest -> match prelude.lookup w counts with
    | Nothing -> countWords rest (prelude.put w 1 counts)
    | Just n -> countWords rest (prelude.put w ((n + 1) :: BigInt) counts)
    end
  end
end

law `dedupe agrees with setOf` is
  definition is `for all` (xs :: List Int32) . dedupe xs = prelude.setOf xs end
end

law `word counts agree with the definition` is
  definition is
    `for all` (words :: List Text) . wordCounts words = countWords words (prelude.keyValOf [])
  end
end

law `the latest put wins` is
  definition is
    `for all` (k :: Text) (v :: BigInt) (w :: BigInt) (m :: KeyVal Text BigInt) .
      prelude.lookup k (prelude.put k w (prelude.put k v m)) = Just w
  end
end
```

A unit that declares a type with one of these names, such as a `Stack` of its
own, uses its own type instead.

## Operations

Every operation is total and is written `prelude.<name>`. The `...Of`
operations build a collection from a list; they are also how a collection is
written as a value.

| Type | Operations |
| --- | --- |
| all five | `size`, `isEmpty`, `toList` (in iteration order) |
| `Set` | `setOf`, `member`, `insert`, `remove`, `union`, `intersection`, `difference` |
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

`Set` elements and `KeyVal` keys need the `Keyed` capability: a total order that
every target agrees on, so a set iterates in the same order everywhere.

| Keyed | Not keyed |
| --- | --- |
| integers, `BigInt`, `Natural`, `Decimal`, `Rational` | `Float32`, `Float64`, `Complex` |
| `Bool`, `Char`, `CodePoint`, `Text`, `Bytes`, `Unit` | `Symbol`, functions |
| data, `List`, `Maybe`, `Either`, `Set` and `KeyVal` whose fields are keyed | |

The order:

- exact numbers by value;
- text by code point, bytes by octet, and `false` before `true`;
- lists element by element, a prefix first; `Nothing` before `Just`;
- other data by constructor, then by fields left to right.

`Set Float64` is rejected: `Float64` has no portable order (`NaN`, `-0`).
A definition that orders its arguments may require `Keyed a`.

## Native types

Adapters receive and return each target's own collections. The generated
codecs sort and deduplicate a set and keep the last value for a repeated key.

| Target | `Set` | `KeyVal` | `Queue`, `Deque` | `Stack` |
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

Collections are generated from generated lists, and shrink as lists do. Sets
and KeyVals are then sorted and deduplicated. Boundary values include the empty
collection, a single item, and two items.

## Limits

- `Deque` has no sized variant yet.
- No literal syntax: `prelude.setOf [1, 2]` is the literal.
