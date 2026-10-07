---
id: lawspec.reference.language.matchers
kind: reference
title: Matchers
---
# Matchers

A matcher is a typed predicate that reads like a sentence:
`sortItems xs has same items as xs`. Each one is a `Bool`, so a law may
combine matchers with `&&`, `||` and `implies`, and an example may expect one
to hold.

```lawspec
unit guide.matchers

type Order is
  | Pending id :: Int32
  | Shipped id :: Int32 carrier :: Text
end

sortItems :: List Int32 -> List Int32
slug :: Text -> Text
average :: Int32 -> Int32 -> Float64
ship :: Int32 -> Order

law `sorting keeps every item` is
  definition is
    `for all` (xs :: List Int32) . sortItems xs has same items as xs
  end
end

law `a slug is lowercase words joined by dashes` is
  definition is
    `for all` (title :: Text) . slug title matches regex "([a-z0-9]+(-[a-z0-9]+)*)?"
  end
  example `a title` is
    title = "Hello World"
    expect slug title starts with "hello"
    expect slug title ends with "world"
  end
end

law `the average lies between the two` is
  definition is
    `for all` (a :: Int32) (b :: Int32) .
      average a b is within 0.5 of prelude.Float64 (prelude.quot (a + b) 2)
  end
end

law `shipping gives a shipped order` is
  definition is
    `for all` (id :: Int32) . ship id matches Shipped _ _
  end
end
```

## The matchers

| Matcher | Holds when | Types |
| --- | --- | --- |
| `xs has same items as ys` | the same items, each as many times, in any order | `List a`, with `Eq a` |
| `xs contains x` | `x` is an item of `xs` | `List a` and `a` |
| `t contains part` | `part` occurs in `t` | `Text` |
| `xs contains all of ys` | every item of `ys` is in `xs` | `List a` |
| `xs is subset of ys` | every item of `xs` is in `ys` | `List a` |
| `x is within d of y` | `x` and `y` are at most `d` apart | one numeric type |
| `t starts with p`, `t ends with p` | `p` is a prefix, or a suffix, of `t` | `Text` |
| `t matches regex "..."` | the regex matches all of `t` | `Text` |
| `t matches r` | the same, with `r :: Regex` | `Text` and `Regex` |
| `v matches C p1 p2` | `C` built `v`, and its fields match `p1`, `p2` | any data type |
| `e fails with C p1` | `e` raises a failure that matches `C p1` | see [typed failures](failures.md) |

- A matcher's words come after its subject. A function named `contains` is
  still called as `contains xs x`; only `xs contains x` is the matcher.
- A matcher binds more loosely than `==` and the arithmetic operators, and
  more tightly than `&&` and `||`.
- `is within` compares integers, exact numbers and floats; durations and text
  are rejected. The difference is computed exactly for integers.
- The list matchers are checked LawSpec definitions of the built-in unit
  `lawspec.matchers`, so they mean the same on every target.

## Constructor patterns

`v matches Shipped _ _` names a constructor and a pattern for each of its
fields:

- `_` matches any value;
- a literal (`7`, `"post"`, `true`) matches an equal value;
- a constructor matches what it builds, written in parentheses when it has
  fields: `v matches Cancelled _ (Just _)`.

A pattern with the wrong number of fields is an error.

## Regular expressions

A `Regex` is written `regex "..."`. The compiler checks every regex literal;
one outside the portable dialect is an error that says why. A law cannot
quantify over `Regex`, since LawSpec does not make regexes up.

The dialect is the part of RE2 and ECMAScript in which a pattern means the
same thing in both. A regex matches a whole text, one code point at a time:

| Form | Matches |
| --- | --- |
| a character other than `\ . ^ $ \| ? * + ( ) [ ] { }` | itself |
| `\` and one of those, or `-` or `/` | that character |
| `\n` `\t` `\r` `\f` `\v` | a control character |
| `\d` `\w` `\s` | `[0-9]`, `[A-Za-z0-9_]`, `[ \t\n\r\f\v]` (ASCII only) |
| `\D` `\W` `\S` | any other character |
| `.` | any character but a newline |
| `[abc]`, `[a-z]`, `[^a-z]` | a class; `-` first or last is itself |
| `(...)`, `(?:...)` | a group |
| `a\|b` | either |
| `*` `+` `?` `{n}` `{n,}` `{n,m}` | repetition, with `n <= m <= 1000` |

These are rejected: `^` and `$` (the match is already whole), `\b`,
backreferences, lookaround, named groups, flags, lazy repetition, Unicode
classes such as `\p{L}`, and a repetition of a repetition (`a**`). For a
match anywhere in a text, write `.*a.*`.

Each runtime has its own matcher for this dialect, so no target depends on a
regex library. It follows every position a pattern can reach at once, so it
never backtracks.

## Laws of the matchers

The matchers keep these laws, which `examples/specs/matchers.lawspec` checks
on every target:

- `xs has same items as ys` is the same as `ys has same items as xs`;
- `Cons x xs contains x`;
- `xs is subset of xs` and `xs contains all of xs`;
- `t starts with t`, `t ends with t`, `t contains t` and `t contains ""`;
- `x is within d of x` for every `d >= 0`.

## Failure messages

When a comparison fails, the test prints both values and, for lists and
data, where they first differ, in the portable rendering every target
shares:

```text
| actual=[3, 3, 1], expected=[1, 3, 3] | first difference at item 1: expected 1, actual 3
```

The path names list items and constructor fields, counting from 1:
`item 2, field 1 of Shipped`.
