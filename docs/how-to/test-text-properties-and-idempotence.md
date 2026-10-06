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

law `normalizers agree` is
  definition is
    `equivalent` normalize referenceNormalize
  end
  example `spaces become hyphens; punctuation is preserved` is
    x = "Hello, World!"
    expect normalize x = "Hello,-World!"
    expect referenceNormalize x = "Hello,-World!"
  end
end
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

law `canonicalization reaches a fixed point` is
  definition is
    `idempotent` canonicalize
  end
  example `all trailing slashes are removed in one pass` is
    x = "https://example.com/path///"
    expect canonicalize x = "https://example.com/path"
  end
end
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
