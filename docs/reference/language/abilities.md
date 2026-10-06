# Abilities

An ability names operations that some handler answers: a payment gateway, a
clock, a store. Code says which abilities it uses. Laws about that code hold
for every lawful handler. See [Handlers](handlers.md) for handlers, and
[Abilities and the harness](../../explanation/abilities.md) for the design.

```lawspec
unit guide.payments

type Payment is | Approved cents :: Int32 | Declined end
type Receipt is Receipt cents :: Int32 end
type PaymentError is | Refused | TooLarge end

-- A payment gateway. Its laws bind every handler of it.
ability Gateway is
  authorize :: Int32 -> Payment
  capture :: Int32 -> Receipt
  fee :: Int32
laws
  law `a receipt is for the amount captured` is
    definition is `for all` (cents :: Int32) . capture cents = Receipt cents end
  end
  law `the fee is never negative` is
    definition is fee >= 0 end
  end
end

handler fakeGateway for Gateway is
  authorize cents is if cents <= 10000 then Approved cents else Declined end
  capture cents is Receipt cents end
  fee is 30 end
end

-- A checked definition that uses Gateway. LawSpec infers that.
definition checkout (cents :: Int32) :: Bool is
  match authorize cents with
  | Approved amount -> (match capture amount with | Receipt paid -> paid == cents end)
  | Declined -> false
  end
end

-- A native adapter. Its signature must say what it uses.
charge :: Int32 -> Bool uses Gateway

-- A definition that can fail says what it fails with.
definition pay (cents :: Int32) :: Receipt uses Gateway fails with PaymentError is
  if cents > 100000 then raise TooLarge else
    match authorize cents with
    | Approved amount -> capture amount
    | Declined -> raise Refused
    end
end

law `large payments fail` using fakeGateway is
  definition is
    `for all` (cents :: Int32 where cents > 100000) . prelude.attempt (pay cents) = Left TooLarge
  end
end
```

## Declaring an ability

```lawspec fragment
ability Name is
  operation :: Type
  ...
laws
  law ...
end
```

- An ability's name starts with an uppercase letter. An operation's name
  starts with a lowercase one.
- An operation is written like a signature. It may take no values:
  `fee :: Int32` is called as `fee`.
- Operation names must be unique in the unit, and differ from its functions.
- An operation's type cannot carry a refinement yet. Put the constraint in a
  wrapper type instead.
- The `laws` section is optional. Its laws are written as usual, and must be
  closed: quantify their values with `` `for all` ``.

An ability may take type parameters, written like a type's:
`ability Store (a :: Type) is put :: a -> Unit ... end`. For now a unit uses
a parameterized ability at one type, which its `uses` lists or handlers name.

## Saying what code uses

A signature lists its abilities after its type:

```lawspec fragment
charge :: Order -> Receipt uses Gateway, Clock
refund :: Order -> Receipt uses Gateway fails with RefundError
```

- `uses A, B` names abilities.
- `fails with E` is short for `uses Fail E`. It may follow `uses`, or stand
  alone.
- A signature without a body (a native adapter) must say everything it uses.
  Its native code gets one handler per ability, in this order, before its
  other arguments.
- A checked definition may leave the list out. LawSpec then infers its
  *ability row*: every ability whose operations it performs, and every
  ability of the functions it calls. A definition that lists abilities must
  list at least the ones LawSpec infers.

`lawspec check --json` shows each declaration's row as its `uses`, and each
law's handlers as its `handlers`.

## Failing

`Fail E` is built in. Its operation is `raise`:

- `raise e` aborts with the failure `e`, of type `E`. It may stand where a
  value of any type is expected.
- A definition that uses `raise` must say `fails with E`. Raising a value of
  another type is an error.
- `prelude.attempt e` evaluates `e` and gives `Right` of its value, or `Left`
  of the failure it raised. It may be used in laws.
- `e fails with C _` holds when `e` raises a failure built by `C`; see
  [typed failures](failures.md).
- A failure no law catches fails the test, naming the failure.

Native adapters do not raise `Fail` failures yet.

## Errors

- **Unknown ability**: `there is no ability called Clock in this unit`.
- **Missing row entry**: `checkout uses Clock (through now), but its uses
  list does not say so; add Clock to it`.
- **Raise without `fails with`**: `pay raises a failure, so its signature must
  say what it fails with`.
- **Wrong failure type**: `pay: it raises a failure of type Text, but its row
  is ...`.
- **No handler**: at run time, `no handler for the ability ...`.

## Limits

- Abilities belong to their unit. Another unit cannot import an ability, or
  a definition that uses one.
- Handler clauses cannot use abilities.
- `a; b` does not yet sequence two calls for their effects in a definition.
  In a law, conjuncts joined with `and` run in order.
