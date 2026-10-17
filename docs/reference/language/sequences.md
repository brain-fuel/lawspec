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
    and prelude.at 1 [10, 20, 30] = Just 20
    and prelude.range 0 3 = [0, 1, 2]
  end
end
```

| Operation | Gives |
| --- | --- |
| `a ++ b`, `prelude.append a b` | `a` then `b`: two texts, two `Bytes` or two lists of one type |
| `prelude.slice from to x` | the items of `x` from index `from` up to, not including, `to` |
| `prelude.take n x`, `prelude.drop n x` | the first `n` items, and the rest |
| `prelude.at i x` | `Just` the item at index `i` of a list, or of `Bytes` as a `UInt8`; `Nothing` outside it |
| `prelude.length x` | how many items: code points of a text, octets of `Bytes` |
| `prelude.range from to` | the integers from `from` up to, not including, `to`, of their type |
| `prelude.octets b` | the octets of `Bytes`, a `List UInt8` |
| `prelude.bytesOf xs` | `Bytes` of a `List UInt8` |
| `prelude.utf8 t` | the UTF-8 encoding of a text, as `Bytes` |
| `prelude.textOf n` | an integer, written in decimal |
| `prelude.join separator texts` | a list of texts joined, the separator between each two |

- Indices count from 0: code points of a text, octets of `Bytes`, items of a
  list.
- `slice`, `take` and `drop` are clamped to the sequence: an index before its
  start or past its end stands for the start or the end, so they never fail.
- Every operation is total, and means the same on every target.
- A fold over `Bytes` is a recursion over its octets, as `total` is above.

## Limits

- A text is read by code point; there is no operation on grapheme clusters.
- `Bytes` cannot be decoded back into a text, for now.
