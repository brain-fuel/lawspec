---
id: lawspec.reference.language.failures
kind: reference
title: Typed failures
---
# Typed failures

A definition that can fail says what it fails with, and a law says which
failure it expects. Failures are values of a data type, so a law checks them
with a constructor pattern. For `Fail E`, `raise` and `prelude.attempt`, see
[abilities](abilities.md#failing).

```lawspec
unit guide.failures

type PaymentError is
  | Declined message :: Text
  | Blocked
  | TooLarge limit :: Int32
end

definition charge (cents :: Int32) :: Int32 fails with PaymentError is
  if cents > 100000 then raise (TooLarge 100000) else
    if cents < 0 then raise (Declined "a negative amount") else cents
end

law `large charges fail as too large` is
  definition is
    `for all` (cents :: Int32 where cents > 100000) . charge cents fails with TooLarge _
  end
end

law `negative charges are declined, and say why` is
  definition is
    `for all` (cents :: Int32 where cents < 0) .
      charge cents fails with Declined _ message contains "negative"
  end
  example `minus one` is
    cents = -1
    expect charge cents fails with Declined _
    expect !(charge cents fails with Blocked)
  end
end
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

`e fails with P message contains "text"` also checks the failure's field
named `message`: it must be a `Text` that contains `text`. The failure type
must have such a field; a constructor without one does not match.

In an example, `expect e fails with P` states the expectation; `expect`
without `=` takes any `Bool`.

## Native failures

A native adapter's failures reach a law through the `Fail` ability, so
`fails with` checks them like any other:

```lawspec fragment
refund :: Int32 -> Int32 fails with PaymentError
async settle :: Int32 -> Int32 fails with PaymentError

law `refunds over the limit are too large` is
  definition is
    `for all` (cents :: Int32 where cents > 5000) . refund cents fails with TooLarge 5000
  end
end
```

The native code raises the runtime's `Fail` with a value of the failure
type, synchronously or from an async adapter:

| Target | Raising a failure |
| --- | --- |
| Python | `raise ls.Fail(data.PaymentErrorTooLarge(5000))` |
| JavaScript, TypeScript | `throw new ls.Fail(new data.PaymentErrorTooLarge(5000))` |
| Go | `panic(LawSpecFail{Value: PaymentErrorTooLarge{Limit: 5000}})` |
| Java | `throw new LawSpecRuntime.Fail(new lawspec.data.PaymentError.TooLarge(5000))` |
| Kotlin | `throw LawSpecRuntime.Fail(lawspec.data.PaymentError.TooLarge(5000))` |
| Rust | `ls::fail(PaymentError::TooLarge { limit: 5000 })` |
| Haskell | `throwIO (LS.Fail (Data.PaymentErrorTooLarge 5000))` |

An application that raises its own exceptions maps them to constructors in
`lawspec.json` under `failures` (see [Handlers](handlers.md)); that mapping
is the implementation plane, never part of a law. A mapped constructor with
one `Text` field named `message` gets the exception's message, so `fails
with Rejected _ message contains "negative"` checks it. The suites
`examples/specs/failures.lawspec` and `examples/specs/handler_bindings.lawspec`
show both.
