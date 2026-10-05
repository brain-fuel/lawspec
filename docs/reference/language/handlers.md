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
- Handler clauses cannot use abilities yet.

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
- `recording` before either: the same handlers, recorded.

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

A native adapter that `uses Gateway` takes the handler first:
`charge(gateway, value0)`. In Haskell its result is in `IO`.

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

## Limits

- Handlers are tail-resumptive or aborting: an operation answers and
  continues, or aborts to `prelude.attempt`. No handler captures a
  continuation.
- A law can install handlers; a definition cannot install one around part of
  its body yet.
