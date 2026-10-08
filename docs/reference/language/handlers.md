---
id: lawspec.reference.language.handlers
kind: reference
title: Handlers
---
# Handlers

A handler gives an ability's operations meaning. LawSpec has three kinds:

- **Spec handlers**, written in LawSpec: fakes, models, test doubles.
- **The native production handler**, written by hand on each target, or bound
  to existing code in `lawspec.json`.
- **Recordings**, built in: `recording h` wraps any handler and counts its
  calls.

See [Abilities](abilities.md) for declaring abilities.

```lawspec
unit guide.store

ability Store is
  put :: Int32 -> Unit
  size :: Integer
laws
  law `size is never negative` is
    definition is size >= 0 end
  end
end

-- A handler with state: the items stored so far.
handler memoryStore for Store with state items :: List Int32 start [] is
  put item is ~items := Cons item items; unitValue end
  size is prelude.length items end
end

-- A handler without state.
handler emptyStore for Store is
  put item is unitValue end
  size is 0 end
end
```

## Spec handlers

```lawspec fragment
handler name for Ability [with state s :: Type start value] is
  operation x y is body end
  ...
end
```

- A handler has one clause for each operation of its ability, no more and
  no fewer. A clause names the operation's values; their types come from the
  operation.
- Each clause is a checked definition, named after the handler and the
  operation: `fakeGateway`'s `authorize` clause is `fakeGatewayAuthorize`.
  The totality audit proves it like any definition. Its result must have the
  operation's type.
- With `with state s :: S start value`, each handler starts with the state
  `value`. A clause reads it as `s`, and may update it with `~s := e;` before
  its result. Each update sees the state the ones before it left.
- A clause may use other abilities, as any definition may. A law that runs
  under the handler then needs handlers for them too: the first lawful one
  of each, unless it names one with `using`. A clause cannot use the ability
  its handler handles.

## Handling part of a definition

```lawspec fragment
definition trial (cents :: Int32) :: Bool is
  handle checkout cents with fakeGateway end
end
```

- `handle e with h end` runs `e` with the spec handler `h` answering its
  ability. A fresh `h` is made each time, with its starting state.
- The definition does not use `h`'s ability: its row leaves it out, and
  adds what `h`'s clauses use.
- `h` may be an imported handler, by its name or `alias.name`.

## Choosing handlers in a law

**A law says what must hold for every lawful handler.** A law names a
handler with `using` only when the handler is part of the claim.

```lawspec fragment
law `checkout captures once` using recording Gateway is ... end
law `large payments fail` using fakeGateway is ... end
```

`using` takes a list:

- a spec handler's name: the law runs under that handler;
- an ability's name: the law runs under each lawful handler of it, as if
  unnamed;
- `recording` before either: the same handlers, recorded;
- `virtual clock` and `seeded random n`: the built-in spec handlers of
  `Clock` and `Random` (see [time](time.md) and [randomness](randomness.md)).

For each ability the law uses but does not name, the law runs under each
lawful handler in turn: the native production handler, then each spec
handler. Each run is its own law, named with the handlers it runs under:
`checkout captures once [recording fakeGateway]`. The harness will choose
among these; for now LawSpec runs them all.

Each case of a law starts with fresh handlers. A recording therefore counts
only the calls of the current case.

## Counting calls

Under a recording handler, a law may count the calls an operation got:

- `calls of capture` is how many times `capture` was called, an `Int64`.
- `calls of capture with (cents)` counts only the calls with these values,
  compared with `=`.

A law that counts calls of an operation must use a recording of its ability.
A law's conjuncts run in order, so a count sees the calls the conjuncts
before it made:

```lawspec fragment
law `checkout captures once, when it succeeds` using recording Gateway is
  definition is
    `for all` (cents :: Int32) .
      (if checkout cents then calls of capture with (cents) == 1 else calls of capture == 0) = true
  end
end
```

## Ability laws

Every ability law is an obligation on every handler. LawSpec makes one law
for each pair: `Gateway: a receipt is for the amount captured [fakeGateway]`.

- For a spec handler without state, the compiler proves the law when it can,
  and checks every case of a finite domain. A handler that breaks the law
  over a finite domain is a compile error.
- For a spec handler with state, and for the native handler, the generated
  tests check the law.

The evidence report lists each pair as its own obligation.

## Native interfaces

Each ability becomes one native interface on each target. Generated code
passes handlers through the context it gives every definition. Native code
gets them as arguments.

| Target | Ability | Production handler, written by hand |
| --- | --- | --- |
| Python | `class Gateway(typing.Protocol)` in `lawspec_abilities/<unit>.py` | `class GatewayHandler` in the unit's module |
| JavaScript | (none) | `export class GatewayHandler` in the unit's module |
| TypeScript | `export interface Gateway` in `lawspec_abilities/<unit>.ts` | `export class GatewayHandler implements abilities.Gateway` |
| Go | `type Gateway interface` in the unit's package | `type GatewayHandler struct{}` and `func NewGatewayHandler() Gateway` |
| Java | `lawspec.abilities.<unit>.<Unit>.Gateway` | nested `public static final class GatewayHandler` in the unit's class |
| Kotlin | `lawspec.abilities.<unit>.<Unit>.Gateway` | nested `class GatewayHandler` in the unit's object |
| Rust | `pub trait Gateway: Send + Sync` in `lawspec_abilities::<unit>` | `#[derive(Default)] pub struct GatewayHandler` implementing it |
| Haskell | `data Gateway` record of `IO` operations in `LawSpecAbilities.<Unit>` | `gatewayHandler :: IO Abilities.Gateway` |

Spec handlers and recordings are generated beside the interface:

- Python, JavaScript, TypeScript, Java, Kotlin: classes `FakeGateway` and
  `GatewayRecording`.
- Go: `NewFakeGateway(symbols)` and `NewGatewayRecording(inner, symbols)`.
- Rust: `FakeGateway::new(&ctx)` and `GatewayRecording::new(inner)`.
- Haskell: `fakeGateway :: SymbolContext -> IO Gateway` and
  `gatewayRecording`, in `LawSpecHandlers.<Unit>`.

Java and Kotlin nest a unit's interfaces, spec handlers and recordings in one
class named after the unit (`example.payments` gives `Payments`). A nested
type may not share that name, nor another piece's, so on those targets an
ability named like the unit (`ability Payments` in `example.payments`), or a
handler whose class would be (`handler payments`), is a compile error that
says which to rename.

A native adapter that `uses Gateway` takes the handler first:
`charge(gateway, value0)`. In Haskell its result is in `IO`.

Native code that calls a checked definition passes its handlers the same
way. The generated function for `checkout` takes the context, then a Gateway
handler, then its values, and installs the handler before it runs:
`checkout(symbols, gateway, cents)` in Python.

### Erlang, Elixir and Gleam

BEAM adapters receive generated ability interfaces before their ordinary
arguments. Each operation is a function, including an operation such as
`fee` that takes no arguments.

| Target | Gateway interface | Call an operation |
| --- | --- | --- |
| Erlang | A map typed by `lawspec_abilities_example_abilities:gateway()` | `(maps:get(capture, Gateway))(Cents)` |
| Elixir | `%LawSpec.Abilities.Example.Abilities.Gateway{}` with function fields | `gateway.capture.(cents)` |
| Gleam | The opaque `Gateway` in `lawspec/abilities/example/abilities`, built by `gateway(authorize, capture, fee)` | `abilities.gateway_capture(gateway, cents)` |

The editable adapter module supplies `gateway_handler()` as its production
factory. Generic instances have separate interfaces and factories, such as
`StoreInt32` and `store_int32_handler()`.

Public checked definitions take handlers first, followed by their values:
`checkout(gateway, cents)`. The generated interface carries its context into
that call. A nested `handle` expression supplies the current handlers to
spec clauses, including after a call through native code.

Spec handler constructors take a scoped context. Erlang uses
`lawspec_abilities:with_context/1`; Elixir uses
`:lawspec_abilities.with_context/1`; Gleam uses
`lawspec/effects.with_context`. For example, in Gleam:

```gleam
import example/abilities/definitions
import lawspec/abilities/example/abilities
import lawspec/effects

pub fn try_checkout(cents: Int) -> Bool {
  effects.with_context(fn(context) {
    let handler = abilities.keeping_gateway(context)
    definitions.checkout(handler, cents)
  })
}
```

Erlang puts spec constructors such as `keeping_gateway(Context)` in the
ability module; Elixir puts them in `LawSpec.Handlers.ExampleAbilities`.
`recording_gateway(context, handler)` wraps an interface in the same scope.
Generated tests make fresh production, spec and recording handlers for
each example, boundary case and property trial. An example's additional
expectations share the recordings from its law body.

BEAM stateful operations are serialized per cell. Calls between handlers
may wait normally; a cycle of waiting stateful operations fails with
`cyclic_handler_dependency`, including calls through LawSpec's parallel
workers. A failed operation keeps its previous state. The dependency
tracker releases completed and cancelled calls and stops after the last
cell closes.

Native factories may use scoped cells for state. Erlang and Elixir call
`lawspec_beam_effects:native_cell/1`, `native_read/1` and `native_write/2`
(using Elixir's remote-call syntax). Gleam has typed `effects.new_cell`,
`read_cell` and `write_cell`. Cells serialize access and are released when
the scope ends, including failure or cancellation. Allocate them in a
production factory or a `with_context` callback, and keep calls that use
them inside that scope. A sequence of separate reads and writes is not an
atomic update.

## Binding a production handler

In a unit with bound adapters, or to use existing code, bind each ability's
production handler under `handlers` in the native bindings of `lawspec.json`:

```json
"handlers": [
  {"ability": "example.abilities::Gateway", "native": ["payments", "StripeGateway"]}
]
```

`native` names something the tests call with no arguments to make the
handler: a class or function (a `default` function in Rust, an `IO` action
in Haskell, a function in the unit's package in Go). It must implement the
ability's interface.

A parameterized ability is bound by its instance's name:
`"example.shop::StoreInt32"`.

In Python and JavaScript the bound handler's operations take and give the
bound native types from `types`. In the typed targets a bound unit's bridge
generates a wrapper, `<Ability>Bound`, that implements the generated
interface around the bound handler and converts each operation's values with
the native types. In Rust the bound handler's type must be `Default`; in
Haskell it is a record of `IO` functions named like the operations, made by
an `IO` action. A bound adapter that uses abilities gets its handlers as the
generated interfaces.

For BEAM targets, the bound factory also takes no arguments. Erlang and
Elixir return a map of operation functions; Gleam returns a public record
with those function fields. These operations use the application's bound
data types. The generated bridge converts their arguments and results
through the checked schema. A bound adapter still receives the canonical
generated ability interface. If a unit's adapters are bound, bind its
production handlers too.

## Native failures

Application code that fails with its own exceptions maps them to failure
constructors under `failures` in `lawspec.json`:

```json
"failures": [
  {"native": ["till", "native", "CardDeclined"], "failure": "example.till::PayError::Declined"},
  {"native": ["till", "native", "BadAmount"], "failure": "example.till::PayError::Rejected"}
]
```

- `native` names an exception class (Python, JavaScript, Java, Kotlin), an
  error type (Go, matched with `errors.As`), an exception type (Haskell) or a
  panic payload type (Rust).
- `failure` names a constructor of the failure type: one with no fields, or
  one `Text` field, which gets the exception's message (its `Debug` text in
  Rust, `show` in Haskell).
- Where a law calls an adapter that `fails with` the type, the mapped
  exception becomes that failure, as if the adapter had raised it.

On Elixir, `native` is the exception module's path, such as
`["Payments", "CardDeclined"]`. The mapping uses `Exception.message/1`.

On Erlang and Gleam, `native` is one atom naming an Erlang error reason,
such as `["card_declined"]`. It matches `error(card_declined)` and an error
tuple whose first element is `card_declined`. In `{card_declined, Message}`,
a binary `Message` becomes the failure's text; other matching reasons use
their printed Erlang term. Gleam code can raise these errors through its
Erlang FFI. These mappings apply to exceptions of class `error`.

## Spec handlers with state, at compile time

A law that runs under spec handlers with state is evaluated by the compiler
when its domain is finite and it calls no adapter: each case starts the
handlers afresh and threads their state through the operations in the order
the law performs them. A false law is a compile error, as for a law over
definitions. Otherwise the generated tests check it.

## Limits

- Handlers are tail-resumptive or aborting: an operation answers and
  continues, or aborts to `prelude.attempt`. No handler captures a
  continuation.
- `handle ... with h end` names a spec handler; a native handler is chosen
  by the law.
- A workflow's call to an adapter catches the runtime's `Fail`; the
  `failures` mapping applies where laws call adapters.
