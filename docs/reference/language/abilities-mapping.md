# Existing features as abilities

Before abilities, LawSpec had several effect-like features, each with its own
syntax: asynchronous adapters, workflow policies, protocols, mailboxes,
actors, supervisors, models, scenarios and distribution. Each is now an
[ability](abilities.md), or a program over abilities. The syntax stays, as
sugar, and every program means what it meant before. This page shows what
each feature is in terms of abilities, and which handler answers it by
default.

`lawspec check --json` shows the mapping for a program: each unit lists its
constructs under `abilityRows`, with what each uses and the handler that
answers it.

| Feature | As abilities | Default handler |
| --- | --- | --- |
| `async f ::` | `f :: ... uses Async` | the target's native async |
| Workflow policies | `Async`, `Clock` and `Fail StageFailure`, with the policies as handler transformers of `lawspec.resilience` | the workflow runtime, on the `Clock` handler a law installs |
| `protocol P` | `Session P` | typed channel ends; between nodes, the `Network` handler |
| `mailbox m of T` | `Mailbox T`; `receive … within d` uses `Clock` | the runtime's mailbox |
| `actor` | `Process`, with the actor's state as a `State` handler | the actor runtime |
| `supervisor` | `Process`, with a `Fail` handler that restarts | the supervisor runtime |
| `model` | `State`: the reference model is a stateful spec handler | the native system, checked against it through `abstract` |
| `scenario` | a program over `Session`, `Mailbox` and `Process` | the `Scheduler` handler |
| Distribution | `Network`; each transport is a handler | the secure transport |

Abilities without a declaring unit are built in, as `Fail` is: their keys
are `lawspec::ability::<Name>`. `Async` is `lawspec.concurrent`'s and
`Clock` is `lawspec.time`'s.

## Async

`async` before a signature and `uses Async` after it mean the same:

```lawspec fragment
async price :: Text -> Int32
price :: Text -> Int32 uses Async     -- the same declaration
```

Both make an asynchronous adapter (see [async functions](async-functions.md)):
its native code returns the target's task, and the generated tests await it.
The `Async` handler of an adapter is the target's own async (Python's
`asyncio`, JavaScript's promises, Java's `CompletableFuture`, Kotlin's
coroutines, Go's goroutines, Haskell's `IO`, Rust's futures), so its native
code gets no handler argument for it. A unit that declares an ability of
its own called `Async` keeps that ability, and `uses Async` then means it.

The default handler offers more than `pause`, the one operation LawSpec code
performs: it starts a function as a task (`spawn`), waits for one, and runs
several side by side. Workflows run their `all` groups and their
asynchronous steps through it. These take native functions, so they are
methods of the native handler rather than LawSpec operations.

## Workflows and policies

A workflow's steps are adapters. Its policies are handler transformers:
each takes the handlers the step runs under and gives handlers that behave
as the policy says.

| Policy | Transforms | Uses |
| --- | --- | --- |
| `timeout d` | `Async`: an attempt that has not finished when `d` has passed on the clock fails | `Clock`, `Fail StageFailure` (`TimedOut`) |
| `hedge d [max n]` | `Async`: another attempt starts when one has not succeeded after `d` | `Clock` |
| `retry …` | the step: a failed attempt is tried again after a wait | `Clock`, and `Random` for jitter |
| `rateLimit …`, `bulkhead …` | the step: a call waits, or fails | `Clock`, `Fail StageFailure` |
| `circuitBreaker …` | the step: calls fail while the breaker is open | `Clock`, `Fail StageFailure` |
| `cache ttl` | the step: a recent success is reused | `Clock` |

Their state machines and laws are those of `lawspec.resilience`, unchanged.
Time comes from the `Clock` ability: a law that runs under `using virtual
clock` runs its workflows on that clock, so every wait passes at once and
every timeout is decided by the time the clock reports. The generated tests
run workflows on a virtual clock, with timeouts and hedges on (see
[workflows](workflows.md#running-workflows)).

## Sessions and channels

A protocol `P` is the ability `Session P`. Each step is an operation: a send
or a receive of the step's type, then the session of the remaining steps.
[Flow types](flow-types.md) give the typestate: an end that has taken a step
is used up, and the next end is the only one that can take the next. The
runtime's channels are its default handler, and between nodes the
`Network` handler carries them.

## Mailboxes

`mailbox m of T` is the ability `Mailbox T`:

- `send m value` never waits;
- `receive m x` waits for the next message;
- `receive … within d` waits at most `d` on the `Clock` and gives `Maybe T`:
  `Just` the message, or `Nothing` when none came. The typed mailboxes have
  it on every target (`receive_within`, `receiveWithin`, `ReceiveWithin`).

## Actors and supervisors

An actor is a process: the `Process` ability spawns it, links it to others,
and monitors it. Its state is a `State` handler: each message's handler is a
clause that reads and replaces it, one message at a time.

A supervisor is a handler of `Fail`: when a child fails, it restarts the
children its strategy names (one for one, one for all, rest for one), within
its restart limit, and otherwise fails itself, to its own supervisor.

## Models

A model is an ability whose commands are its operations. The reference is a
stateful spec handler: its state is the model state, and each command's
reference definition is a clause. The system is the native handler. Checking
a model checks the native handler against the spec handler, through
`abstract` (refinement). Consistency levels (linearizable, sequential,
causal, eventual) say how a history of concurrent operations must agree with
the spec handler.

## Scenarios

A scenario is a program over `Session`, `Mailbox` and `Process`. It runs
under a `Scheduler` handler, which chooses the order processes take turns
in, crashes one in some runs, and carries channels over a faulty network in
others. "For every schedule" is the law. The seed that replays a schedule
belongs to the run, not the law.

## Distribution

Nodes talk through the `Network` ability. Each transport (in memory, TCP,
HTTP) is a handler of it, and the default is secure: a post-quantum
handshake, node identities and sealed frames (see
[distribution](distribution.md#security)). An in-memory transport without the
handshake exists for tests only.
