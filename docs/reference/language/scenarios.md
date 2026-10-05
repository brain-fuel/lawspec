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
| `par ... with ... end` | Runs its branches at the same time. |
| `expect x = value` | `x` must equal the constant on every schedule. |

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
- Every model command's call and return are recorded.
- The history must be linearizable against the model, and every `expect`
  must hold.

`lawspec evidence` lists these runs as property-tested.

The [models example](../../../examples/specs/models.lawspec) has a reply
over a channel, a reply handed to a worker, and two increments at once.
