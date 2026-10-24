---
id: lawspec.reference.language.abilities
kind: reference
title: Abilities
---
# Abilities

An ability names operations that some handler answers: a payment gateway, a
clock, a store. Code says which abilities it uses. Laws about that code hold
for every lawful handler. See [Handlers](handlers.md) for handlers, and
[Abilities and the harness](../../explanation/abilities.md) for the design.

```lawspec
unit guide.payments

type Payment is one of | Approved  of type Int32 | Declined end type
type Receipt is a record{  cents :: Int32} end type
type PaymentError is one of | Refused | TooLarge end type

-- A payment gateway. Its laws bind every handler of it.
ability Gateway is
authorize :: Int32 -> Payment
capture :: Int32 -> Receipt
fee :: Int32
laws
law "|a receipt is for the amount captured| is
  definition : for all (cents :: Int32) => capture cents = Receipt record{ cents
        = cents} end for all end definition
end law
law "|the fee is never negative| is
  definition : fee >= 0 end definition
end law

end laws
end ability

handler fakeGateway for Gateway is
 operation authorize cents is if cents <= 10000 then Approved cents else Declined end if
end operation
 operation capture cents is Receipt record{ cents = cents} end operation
 operation fee is 30 end operation
end handler

-- A checked definition that uses Gateway. LawSpec infers that.
procedure checkout (cents :: Int32) -> Bool is
  first matching case of authorize cents :
    when Approved amount then (first matching case of capture amount : when
        Receipt record{ cents = paid} then paid = cents end case)
        when Declined then false
      end case
    end procedure

    -- A native adapter. Its signature must say what it uses.
    charge :: Int32 -> Bool uses Gateway

    -- A definition that can fail says what it fails with.
    procedure pay (cents :: Int32) -> Receipt uses Gateway fails with
      PaymentError
      is
      if cents > 100000 then raise TooLarge else
        first matching case of authorize cents :
          when Approved amount then capture amount
          when Declined then raise Refused
        end case end if
    end procedure

    law "|large payments fail| using fakeGateway is
      definition :
        for all (cents :: Int32 where cents > 100000) => prelude.attempt (pay
          cents) = Left TooLarge end for all
      end definition
    end law

end unit
```

## Declaring an ability

```lawspec fragment
ability Name is
  operationName :: Type
  ...
  laws
    law requirement is
      definition:
        ...
      end definition
    end law
  end laws
end ability
```

- An ability's name starts with an uppercase letter. An operation's name
  starts with a lowercase one.
- An operation is written like a signature. It may take no values:
  `fee :: Int32` is called as `fee`.
- Operation names must be unique in the unit, and differ from its functions.
- An operation's type may carry refinements. Its arguments are checked
  where code calls it, and every handler owes its result's refinement: each
  becomes a law, `` Meter: reading gives what its type says ``, checked for
  each handler like the ability's own laws.
- A definition may rely on an operation's refined result. Where it performs
  the operation, the generated code checks the result first, and stops the
  definition if a handler broke the type. The definition's own checks then
  know the result has its refinement. `lawspec evidence` lists each check as
  `runtime-checked`. The handler law above is still tested, never assumed.
- An operation may fail, as a signature may: `send :: Record -> Int64 fails
  with KafkaError`. Code that performs it fails with `KafkaError` too, and a
  law catches it with `prelude.attempt` or `fails with`. A spec handler's
  clause for it may `raise`; a native handler raises the runtime's `Fail` (see
  [Failing](#failing)). A clause that fails with a failure its operation does
  not name is an error.
- The `laws` section is optional. Its laws are written as usual, and must be
  closed: quantify their values with `for all (...) => ... end`.

An ability's native handlers may share a resource, written after its name:
`ability Broker with Cluster is ... end`. Each case that runs a native
handler of `Broker` acquires one `Cluster` (by its [resource
declaration](resources.md)) and makes the handler with it, as every other
native handler made `with Cluster` in the case; a law that takes a `Cluster`
itself gets the same one. Native handlers made with one resource are one
system, so a law never runs some of them natively and others under spec
handlers. The production handler takes the resource when it is made:
`BrokerHandler(cluster)` in Python, `NewBrokerHandler(cluster)` in Go,
`BrokerHandler::new(cluster)` in Rust, `brokerHandler cluster` in Haskell.

An ability may take type parameters, written like a type's:
`ability Store (a :: Type) is put :: a -> Unit ... end`. A unit may use it at
several types, such as `Store Int32` and `Store Text`. Each is its own
ability: its own handlers, row entries and native interface (`StoreInt32`).
A definition that uses a parameterized ability at more than one type in its
unit must say which, with `uses Store Int32`.

A type argument may be a refinement: `uses Store Count`, or
`handler counts for Store Count`, with
`refinement Count is (c :: Int32 where c >= 0) end refinement`. The ability
is then `Store` at Count's base type, with the same native interface
(`StoreInt32`). The refinement adds the result checks and handler laws above.

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
  of the failure it raised. It may be used in laws and definitions; a
  definition that attempts what fails does not fail itself.
- `e fails with C _` holds when `e` raises a failure built by `C`; see
  [typed failures](failures.md).
- A failure no law catches fails the test, naming the failure.

A native adapter that `fails with E`, or a native handler's operation that
fails with `E`, fails by raising the runtime's `Fail` with a native `E`:

| Target | Native code fails with |
| --- | --- |
| Python | `raise ls.Fail(value)` |
| JavaScript, TypeScript | `throw new ls.Fail(value)` |
| Go | `panic(LawSpecFail{Value: value})` |
| Java, Kotlin | `throw new LawSpecRuntime.Fail(value)` |
| Rust | `ls::fail(value)` |
| Haskell | `throwIO (LS.Fail value)` |

Application code that throws its own exceptions can keep them: `failures` in
`lawspec.edn` maps each to a failure constructor (see
[Handlers](handlers.md#native-failures)).

## Effects in order

A definition orders the operations it performs:

```lawspec fragment
procedure buy (cents :: Int32) -> Bool uses Gateway, Log is
  note "buying";
  let approved = checkout cents in
  note "bought";
  approved end let
end procedure
```

- `a; b` runs `a`, then gives `b`. An operation that gives `Unit`, such as
  `note`, is called this way for its effect.
- `let x = e in body` runs `e` once and names its value in `body`.
- Each is an ordinary expression, so it may appear in a law as well.

## Abilities across units

`import` brings a unit's abilities and handlers with it. An imported
ability's operations are called like the unit's own, and the importer's
definitions may use it. Its native interface, production handler and
recording stay with the unit that declares it, so every importer shares
them. A spec handler is copied into each unit that imports it.

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

- Handlers are tail-resumptive or aborting (see [Handlers](handlers.md)).
- An async adapter cannot fail with the runtime's `Fail` yet.
- Two abilities with the same name cannot meet in one unit, even from
  different units.
