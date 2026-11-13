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

type Order is one of
  | Pending  of type Int32
  | Shipped of type record{ id :: Int32 carrier :: Text}
end type

sortItems :: List Int32 -> List Int32
slug :: Text -> Text
average :: Int32 -> Int32 -> Float64
ship :: Int32 -> Order

law "|sorting keeps every item| is
  definition :
    for all (xs :: List Int32) => sortItems xs has same items as xs end for all
  end definition
end law

law "|a slug is lowercase words joined by dashes| is
  definition :
    for all (title :: Text) => slug title matches regex
    "([a-z0-9]+(-[a-z0-9]+)*)?" end for all
  end definition
  example "|a title| :
    title = "Hello World"
    expect slug title starts with "hello"
    expect slug title ends with "world"
  end example
end law

law "|the average lies between the two| is
  definition :
    for all (a :: Int32) (b :: Int32) =>
      average a b is within 0.5 of prelude.Float64 (prelude.quot (a + b) 2) end for all
  end definition
end law

law "|shipping gives a shipped order| is
  definition :
    for all (id :: Int32) => ship id matches Shipped record{ id = _ , carrier =
        _} end for all
  end definition
end law
end unit
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
| `t matches format email` | `t` is in the named format (`email`, `rfc822Address`, `uuid`; see [record rules](record-rules.md#formats)) | `Text` |
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
  fields: `v matches Cancelled _ (Present _)`.

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

## What the address formats accept

Two formats take an email address ([record rules](record-rules.md#formats)).
`email` is the one a form wants. `rfc822Address` is every address RFC 822
allows.

| | `v matches format email` | `v matches format rfc822Address` |
| --- | --- | --- |
| Accepts | one mailbox, `local@domain`, in ASCII | an `address` of RFC 822, section 6.1 |
| Reference | Email::Valid 1.204, `fqdn` on, network checks off | `valid()` of Mail::RFC822::Address 0.3 |
| Relation to it | accepts nothing the module refuses; refuses what it accepts only for the [reasons below](#where-email-is-narrower-than-emailvalid) | accepts exactly what it accepts |
| Checks | two regexes of this dialect and a length | comments removed, then one regex of this dialect |
| Targets | all | Java, JavaScript, TypeScript, Python; `target-unsupported` elsewhere |
| JSON Schema | two `pattern`s and `maxLength`, exactly | refused as `target-unsupported` |

Where they differ:

| Text | `email` | `rfc822Address` |
| --- | --- | --- |
| `ann@example.org` | accepted | accepted |
| `"Ann Lee"@example.org` | accepted | accepted |
| `ann@[10.0.0.1]` | accepted | accepted |
| `ann@example.org (Ann Lee)` | refused | accepted |
| `Ann Lee <ann@example.org>` | refused | accepted |
| `Ann <@a.example,@b.example:ann@example.org>` | refused | accepted |
| `team: ann@example.org, bob@example.org;` | refused | accepted |
| `ann@localhost` | refused | accepted |
| `ann @ example.org` | refused | accepted |
| `ann@example.org` and a line feed | refused | accepted |
| `änn@exämple.org` | refused | accepted |
| `ann@ex_ample.org` | refused | accepted |
| `ann@[999.1.1.1]` | refused | accepted |
| `ann..lee@example.org` | refused | refused |
| `ann@example.org, bob@example.org` | refused | refused |

Every `email` is an `rfc822Address`.

### email

An `email` is a local part, `@` and a domain:

- The local part is words of letters, digits and ``!#$%&'*+/=?^_`{|}~-``
  joined by single dots, or one quoted string of printable ASCII in which
  `"` and `\` are written `\"` and `\\`. It has at most 64 characters, its
  quotation marks included.
- The domain is two or more labels joined by dots, each of letters and
  digits with hyphens inside, or four numbers from 0 to 255 in brackets.
- The whole text has at most 254 characters.

The 64 and the 254 are part of the format: a text that is too long breaks
the rule `<field>.email`, like any other text that is not an `email`. A
label's own length is not limited, as Email::Valid does not limit it.

### Where email is narrower than Email::Valid

Email::Valid looks for an address inside the text it is given and checks
that address. `email` asks whether the whole text is one. So `email`
refuses these, each of which the module accepts:

| Reason, as the recorded vectors name it | Example |
| --- | --- |
| `comment` | `ann@example.org (Ann Lee)` |
| `angle-address`: a display name or angle brackets | `Ann Lee <ann@example.org>` |
| `white-space`: any space, tab or line break outside a quoted string, a final line feed included | `ann @example.org` |
| `control-character`: U+0000 to U+001F or U+007F, which the module allows in a word and in a quoted string | `"a` U+0001 `b"@example.org` |
| `loose-ip-literal`: brackets around anything but four numbers from 0 to 255, or brackets as one label among others | `ann@[999.1.1.1]`, `ann@[1.2.3.4].example.org` |
| `quoted-word-among-atoms`: a quoted string that is not the whole local part | `"a".b@example.org` |

`lawspec-dev email-vectors --email-valid` compared 53,740 texts with the
module. `email` accepted none the module refused, and every text the module
accepted and `email` refused has one of these reasons. 11,626 of the
verdicts are recorded in `test/fixtures/formats/email-valid-vectors.tsv`.
The agreement is tested, not proved.

### rfc822Address

`rfc822Address` first removes comments, as the module's `valid` function
does, and then matches the module's regex. A comment is text in
parentheses outside a quoted string; comments nest, so the innermost is
replaced by one space until none is left. `prelude.rfc822Uncommented text`
is that pass on its own. It is a primitive of the Java, JavaScript,
TypeScript and Python runtimes, and a program that uses the format on
another target is refused with `target-unsupported`.

| Accepted | Example |
| --- | --- |
| a plain mailbox | `ann@example.org` |
| a comment, anywhere outside a quoted string | `ann@example.org (Ann (at work))` |
| a display name | `Ann Lee <ann@example.org>` |
| a route | `Ann <@a.example,@b.example:ann@example.org>` |
| a group of addresses, or an empty group | `team: ann@example.org, Bob <bob@example.org>;` and `team:;` |
| a domain of one label | `ann@example` |
| a domain literal | `ann@[10.0.0.1]` |
| a quoted local part | `"Ann Lee"@example.org` |
| one line feed at the end | `ann@example.org` followed by `\n` |
| white space after a part, folded lines included | `ann @ example.org` |
| letters outside ASCII | `änn@exämple.org` |
| the control characters U+001A to U+001F in a name | see below |

Three of these come from how the module is written, not from RFC 822:

- **The final line feed.** Perl's `$` matches before a last line feed, so
  the module accepts an address followed by exactly one. Two are refused.
- **The control range.** The module excludes controls as `\000-\031`, which
  Perl reads in octal: U+0000 to U+0019. U+001A to U+001F and U+007F are
  therefore ordinary characters of a name.
- **White space in a group.** After a group's comma and semicolon the module
  uses Perl's `\s`, which is Unicode white space; elsewhere only a space, a
  tab and a folded line count.

These are refused: an empty text, a text without `@`, two addresses outside
a group (`ann@example.org, bob@example.org`), two dots in a row, and a
parenthesis that opens no comment or closes none.

The module's two verdicts on 11,442 texts, its regex alone and `valid()`,
are recorded in `test/fixtures/formats/email-vectors.tsv`; the agreement
with both is tested, not proved.

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
