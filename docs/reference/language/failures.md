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
      TooLarge _ end
  end
end

law "|negative charges are declined, and say why| is
  definition :
    for all (cents :: Int32 where cents < 0) =>
      charge cents fails with Declined record{ message = _} message contains
    "negative" end
  end
  example "|minus one| :
    cents = -1
    expect charge cents fails with Declined record{ message = _}
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
    end
  end
end
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
`lawspec.json` under `failures` (see [Handlers](handlers.md)); that mapping
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
