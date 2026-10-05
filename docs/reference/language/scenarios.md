# Protocols and scenarios

A **protocol** lists what one end of a channel sends and receives, in order;
the other end does the reverse. A **scenario** runs a shared
[model](models.md)'s commands from processes that run at the same time and
talk over channels. LawSpec proves, when it compiles a scenario, that it
cannot deadlock and cannot race. It then runs the scenario on many schedules
and checks every run against the model.

```lawspec fragment
protocol Report is
  send Int64
end

scenario `a count is passed on` in counter is
  channel report :: Report
  par
    n <- increment
    send report n
  with
    receive report m
    expect m = 1
  end
end
```

## Protocols

```text
protocol Name is
  send Type
  receive Type
  ...
end
```

`! Type` and `? Type` are the same as `send Type` and `receive Type`. Steps
may be separated by `.`.

A step whose type is another protocol sends an end of a channel following
that protocol. This is how a process hands a conversation to another
(delegation).

## Scenarios

```text
scenario `name` in model is
  channel c :: Protocol
  statements
end
```

| Statement | Meaning |
| --- | --- |
| `x <- command arguments` | Runs a model command (its handle is passed for you) and binds the result. A command's arguments are on its own line. |
| `command arguments` | Runs a command, ignoring the result. |
| `send c value` | Sends a value, or a channel end the process holds, on `c`. |
| `receive c x` | Receives from `c` into `x`. |
| `receive c x or else ... end` | As above, but if the process at the other end has failed, the statements between `or else` and `end` run instead of the rest of this process. |
| `par ... with ... end` | Runs its branches at the same time. |
| `expect x = value` | `x` must equal the constant on every schedule. |
| `mailbox m of Type` (beside `channel`) | A mailbox: any process may `send m value`, and one process takes them with `receive m x`. |

In a `par`, the first branch to use a channel follows its protocol, and the
other branch follows the reverse.

## What LawSpec proves

These checks run when the scenario compiles:

- **Each channel joins exactly two processes**: the branches of one `par`.
- **The channels form a tree** over the processes. A cycle is an error naming
  the channel that closes it, since processes waiting on each other in a
  cycle could deadlock.
- **Each end follows its protocol**, step by step, to the end. A step out of
  order, or a protocol left unfinished, is an error.
- **A channel end has one owner.** Sending it gives it up, and using it
  afterwards is an error. Data is copied.

## When a process fails

A process can fail: a command raises, or it stops part way. The channel
ends it still holds are then given up, including ends on their way to it,
and LawSpec treats every channel as **affine** (usable at most once, with
no promise that it finishes):

- A `receive` from a process that has failed gets everything sent before
  the failure, then fails instead of waiting. The receiving process fails
  too, unless the receive has an `or else`.
- A process whose par branch fails also fails.
- `or else` runs instead of the rest of the process. It cannot use the
  value that never arrived, and channel ends it leaves unfinished are
  given up in turn.

```lawspec fragment
scenario `a receipt, or the balance if the teller fails` in account is
  channel receipt :: Receipt
  par
    n <- deposit 5
    send receipt n
  with
    receive receipt m or else
      balance
    end
    expect m = 5
  end
end
```

So a failure can stop processes, but never leaves one waiting forever:
deadlock freedom holds with failures too.

## Mailboxes

A channel joins two processes. A **mailbox** takes messages from any number
of processes, and one process receives them, in the order they arrive:

```lawspec fragment
scenario `two tellers report to one auditor` in account is
  mailbox reports of Int64
  par
    n <- deposit 3
    send reports n
  with
    m <- deposit 4
    send reports m
  with
    receive reports first
    receive reports second
  end
end
```

LawSpec checks that:

- one process receives from each mailbox;
- every message sent is received: as many receives as sends, and none
  inside an `or else`;
- each sender is joined to the receiver as a channel would join them, so
  channels and mailboxes together still form a tree.

A send never waits, and the receiver waits only for messages that will
come. So the proof of deadlock freedom still holds. If a sender fails
before it sends, the receive that would have taken its message fails, or
runs its `or else`.

A channel end only travels over a channel, which joins its sender and its
receiver. So delegation keeps the processes a tree. Together these make a
scenario deadlock-free and race-free by construction. This is the
"propositions as sessions" result of Caires and Pfenning, and Wadler.

`lawspec evidence` lists each scenario as **proved** deadlock-free and
race-free.

## Running scenarios

On every target, a scenario runs 30 times by default:

- Processes run on the target's own concurrency (threads, goroutines, async
  tasks or `forkIO`), with random yields around each call and send.
- Every third run crashes one process of a `par` at a random point. In
  those runs the processes that depend on it may fail, but none may block,
  and what did run must still agree with the model.
- Every third run sends each channel between two nodes of a faulty
  in-memory network that loses, duplicates and delays messages (see
  [distribution](distribution.md)). Channel ends sent over a channel go by
  address. The channels must hide every fault.
- Every model command's call and return are recorded.
- The history must be linearizable against the model, and every `expect`
  must hold.

`lawspec evidence` lists these runs as property-tested.

The [models example](../../../examples/specs/models.lawspec) has a reply
over a channel, a reply handed to a worker, and two increments at once.

## Typed channel ends in your code

Every protocol also becomes typed channel ends on each target, for your
implementation code. Each end has a type per step, named after what it does
next, so a send or receive out of order does not compile. An end that has
already been used fails when used again; in Rust it does not compile.

For `protocol Serve is receive Int32 . receive Int32 . send Int64 end`:

| Target | Opening a channel and its steps |
| --- | --- |
| Python | `first, second = lawspec_sessions.Serve.open()`; `x, nxt = first.receive()`; `nxt.send(value)` |
| JavaScript, TypeScript | `const [first, second] = Serve.open()`; `const [x, nxt] = await first.receive()` (receives are asynchronous); `nxt.send(value)` |
| Go | `first, second := OpenServe()`; `x, next := first.Receive()`; `next.Send(value)` |
| Java, Kotlin | `var ends = Serve.open()`; `var got = ends.first().receive()` gives `got.value()` and `got.next()` |
| Rust | `let (first, second) = lawspec_sessions::serve::open()`; `let (x, next) = first.receive()` |
| Haskell | `(first, second) <- openServe`; `(x, next) <- receive first` |

- The first end follows the protocol, and the second end follows the reverse.
- A step whose type is another protocol sends that protocol's first end,
  unused.
- Each runtime also has `spawn` (a process you can join) and `par` (run
  several at once and join them), on the target's own concurrency.
- An end has `abandon()`, which gives up the conversation. A receive whose
  other end was abandoned, or whose process failed, gets what was sent
  before, then fails with `PeerFailed`. Catch it to handle the failure, as
  `or else` does. Rust and Go also have `try_receive` / `TryReceive`, and
  Haskell has `tryReceive`, which return the failure instead.
- Channels go through a small send and receive interface, which a networked
  transport can implement as well.

A protocol's channel can also join two nodes: `P.listen(node, name)` gives
the first end and `P.dial(node, address)` gives the second, on another node.
An end sent to another node keeps working there (see
[distribution](distribution.md)).

The [sessions example](../../../examples/specs/sessions.lawspec) adds two
numbers through a server process, and through a worker that is handed the
server's end.
