# Compare alternative implementations

Use the prelude law `equivalent` to check that two functions agree on every
input: for example, a new implementation against a reference one, or a fast
path against a simple one.

## Write the law

Declare both functions with the same input and output types, and apply
`equivalent` to them:

```lawspec
unit example.formatting

render :: Int32 -> Text
referenceRender :: Int32 -> Text

law `decimal renderers agree` is
  definition is
    `equivalent` render referenceRender
  end
  example `both renderers produce a negative decimal string` is
    x = -42
    expect render x = "-42"
    expect referenceRender x = "-42"
  end
end
```

This expands to:

```text
for all (x :: Int32) . render (x) = referenceRender (x)
```

`equivalent` requires `Eq b`, where `b` is the **result** type. Here the results
are compared with text equality; for `Int32 -> Int32` functions, integer
equality. The example uses the input name `x`, which it inherits from the
prelude law. Run `npx lawspec explain` to see the input names of any law.

## Implement the adapters

Both functions are user-owned adapters, so either may delegate to existing
code. For JavaScript:

```javascript
export const render = x => String(x);
export const referenceRender = x => x.toString(10);
```

The [complete example](../../examples/specs/equivalent.lawspec) also compares
two implementations that clamp negative integers to zero.

## Pin down the expected output

Equivalence alone does not show that either implementation is correct: two
implementations can share the same bug. Add examples with explicit expected
results, as above, so the tests also check specific outputs.

The inputs can come from any supported domain, including structural types.
