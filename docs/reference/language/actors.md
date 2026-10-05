# Actors and supervisors

An **actor** owns a state and handles one message at a time, in the order
the messages arrive. Nothing else touches its state, so its handlers need
no locks. You write each handler as a plain function from the state (and
the message's arguments) to a reply and the next state. LawSpec checks the
handlers against a model, and generates a typed actor that runs them, for
your implementation code.

```lawspec fragment
type Account is Account balance :: Int64 end

openAccount :: Unit -> Account
deposit :: Account -> UInt8 -> Pair Int64 Account
balance :: Account -> Pair Int64 Account
reopen :: Account -> Account

actor account :: Account by Int64 is
  start openAccount by 0
  restart from reopen by modelReopen
  on deposit by modelDeposit
  on balance by modelBalance
end
```

## Declaring an actor

```text
actor name :: State by Model is
  start f by value                  -- or ~ value
  restart from g by reference       -- optional
  on handler by reference [when precondition]
  abstract function
  invariant predicate
end
```

| Line | Meaning |
| --- | --- |
| `start f by e` | `f` makes the actor's first state, and `e` is the model's, as in a [model](models.md). A supervised actor's start takes no arguments. |
| `on h by r` | `h` is a handler: an adapter taking the state first, then the message's arguments, and returning `Pair Reply State`, or the `State` alone when there is no reply. `r` is its reference over the model state, as for a model's command. |
| `restart from g by r` | After a crash, `g :: State -> State` makes the restarted state from the last one, and `r :: Model -> Model` does the same for the model. Without it, a restarted actor starts again from `start`. |
| `abstract`, `invariant` | As in a model, over the actor's own state. |

The actor's handle type is its name, capitalized, followed by `Actor`, so
`actor account` has an `AccountActor`.

## What LawSpec checks

An actor is checked like a shared [model](models.md), with its handlers as
the commands:

- **In sequence.** Generated runs send messages and compare every reply and
  state with the model. One step in eight is a **crash**: the actor restarts
  between messages, and its state must then agree with the restart's
  reference. Crashes shrink like any other step:

  ```text
  model account fails at step 3 of start(()); deposit(4); crash(); balance():
  returned 0; the model returns 4
  ```

- **In parallel.** Messages are sent from several threads at once, and every
  history must linearize, which checks that the actor runtime handles one
  message at a time.
- **In scenarios.** A [scenario](scenarios.md) can run an actor's handlers
  from processes that talk over channels.

## Typed actors in your code

Every actor becomes a class (or its target's equivalent), generated beside
the data types, that runs your handlers:

| Target | Starting and calling |
| --- | --- |
| Python | `a = AccountActor.start()`; `a.deposit(5)` returns the reply; `a.tell_deposit(5)` does not wait |
| JavaScript, TypeScript | `const a = AccountActor.start()`; `await a.deposit(5)`; `a.tellDeposit(5)` |
| Go | `a := StartAccountActor()`; `reply, err := a.Deposit(5)`; `a.TellDeposit(5)` |
| Java, Kotlin | `var a = AccountActor.start()`; `a.deposit(5)`; `a.tellDeposit(5)` |
| Rust | `let a = AccountActor::start()?`; `a.deposit(5)?`; `a.tell_deposit(5)?` |
| Haskell | `a <- startAccountActor accountHandlers`; `accountDeposit a 5`; `tellAccountDeposit a 5` |

- Each call waits for its reply. The tell form sends the message without
  waiting.
- `stop()` refuses later messages. Messages already sent are still handled.
- A handler that fails **crashes** the actor, and its caller gets an
  `ActorCrashed` error. A supervised actor restarts. Any other stops, and
  later messages fail with `ActorStopped`.
- `crash()` crashes the actor on purpose, after the messages already sent,
  for testing how it restarts.
- `monitor(f)` calls `f` after each crash and when the actor stops.
  `link(other)` crashes either actor when the other crashes. A crash crosses
  each link once.
- An actor is not a thread. A message to an idle actor starts a short-lived
  worker (a thread, goroutine, task or green thread) that handles the
  mailbox and then ends. An idle actor costs only its state and its queue.

In Haskell, the handlers come in a record (`accountHandlers`, from
`LawSpecActors.<Unit>.Adapters`), so the adapter module can use its own
actors without an import cycle.

### Actors on other nodes

`serve(node, name)` lets other nodes call an actor, and
`AccountActor.connect(node, address)` gives a proxy with the same handler
methods. A call that gets no reply within the timeout fails with
`Unreachable`. See [distribution](distribution.md).

### Mailboxes

A mailbox is a typed queue with many senders and one receiver:

```lawspec fragment
mailbox jobs of Job
```

Every target gets a `JobsMailbox` with `send` (never waits), `receive`
(optionally with a timeout) and `close`. `serve(node, name)` offers it to
other nodes, and `connect(node, address)` sends to it from another node.

A mailbox is the channel form of an actor: a process that loops over
`receive` and handles each message is an actor written by hand. Use a
mailbox when you want your own loop; use an `actor` declaration to have
LawSpec check the handlers against a model and supervise them. In
[scenarios](scenarios.md#mailboxes), mailboxes are checked for deadlock
freedom like channels.

## Supervisors

A **supervisor** starts actors and restarts them after a crash.

```lawspec fragment
supervisor bank is
  one for one
  at most 3 restarts in 5s
  permanent account
  transient audit
end
```

| Part | Meaning |
| --- | --- |
| `one for one` | Restart only the child that crashed (the default). |
| `one for all` | Restart every child. |
| `rest for one` | Restart the child that crashed and those listed after it. |
| `at most n restarts in d` | More restarts than this within `d` is the supervisor's own failure. The default is 3 in 5s. |
| `permanent c` | Restart `c` after a crash, and also after it stops. |
| `transient c` | Restart `c` after a crash only. |
| `temporary c` | Never restart `c`. |

Children are actors, or other supervisors, started in the order listed. A
supervisor that passes its limit stops being one. If it has a supervisor
of its own, that supervisor restarts all of its children. If not, every
child stops and its monitors are told. A child has one supervisor, and no
supervisor supervises itself.

A restart happens **in place**: the actor keeps its address and the
messages waiting for it, so handles held elsewhere keep working. Its state
comes from `restart from`, or from `start`.

Every supervisor becomes a class such as `BankSupervisor`. Its `start()`
starts the children, which are then available by name: in Python,
`bank = BankSupervisor.start()`, then `bank.account.deposit(5)`. It also
has `stop()`, which stops the children, last first, without restarting
them, and `monitor(f)`.

## Evidence

`lawspec evidence` lists each actor's runs, its parallel histories and its
restarts as property-tested. It lists each supervisor's supervision as
property-tested, by the runtime's own conformance check. That check covers
every strategy, lifetime, restart limit and escalation, and links and
monitors, and runs in the generated tests of every unit with a supervisor.

The [actors example](../../../examples/specs/actors.lawspec) has an
account with a restart, a supervisor, and a scenario that survives a
crashed process.
