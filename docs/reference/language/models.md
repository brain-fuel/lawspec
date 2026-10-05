# Stateful models

A `model` pairs a system's commands with a simpler reference: a model state
and a checked definition for each command. LawSpec generates sequences of
commands, runs them against your adapters, and checks every result and state
against the reference. For a shared model it also runs commands at the same
time and checks that every history is linearizable.

```lawspec fragment
model stack :: Stack n by List Int8 is
  start empty by Nil
  push by modelPush
  pop by modelPop
  abstract toList
end
```

## Declaring a model

```text
model name :: [shared] State by Model is
  start command by value        -- or ~ value
  command by reference [when precondition]
  abstract function
  invariant predicate
end
```

| Line | Meaning |
| --- | --- |
| `start f by e` | `f` makes the first system state. `e` is the first model state: a value when `f` takes `Unit`, otherwise a definition taking the same arguments. |
| `cmd by ref` | `cmd` is an adapter of the system. `ref` is a checked definition taking the command's other arguments, then the model state, and returning `Pair result next` (or the next state alone when the result is `Unit`). |
| `when p` | The command runs only when `p model` holds. |
| `abstract f` | `f` turns the system state into a model state, and must equal the model's at every step. |
| `invariant p` | `p` holds of the model state, or of the system state, after every step. |

`~` reads the same as `by`.

### Linear and shared models

A **linear** model threads a [flow-typed](flow-types.md) state through its
commands. Each command takes the state as a flow parameter (`Stack n / Stack
(n + 1)`), and LawSpec reads each command's typestate from it. A generated run
never pops an empty stack, because `pop` needs `Stack (n + 1)`. Linear models
run in sequence.

A **shared** model's commands take one handle, which every caller shares.
Its type never changes, so it cannot be indexed. Preconditions come from the
model state (`when`). Shared models also run in parallel.

```lawspec fragment
model counter :: shared Counter by Int64 is
  start newCounter ~ 0
  increment ~ modelIncrement
  decrement ~ modelDecrement when positive
  read ~ modelRead
end
```

## What LawSpec checks

**In sequence.**
- LawSpec generates runs of up to 20 commands by simulating the model, so
  every step is allowed by typestate, its precondition and its reference.
- It runs each command against your adapters and compares the result, the
  abstracted state and the invariants with the model after every step.
- A failing run is shrunk: commands are dropped and arguments made smaller
  until nothing smaller still fails.

**In parallel (shared models).**
- A case is a short sequential prefix, then a branch per thread (three by
  default). The branches are generated so that the model allows every
  interleaving of them.
- They run at the same time, with random yields and short sleeps around
  calls, and every call's start and return are recorded.
- The history must be linearizable: some order of the calls that keeps each
  call after those that returned before it started must give every result,
  and leave the state, the model gives.
- Each case runs several times, since races depend on the schedule.

A non-atomic counter fails like this:

```text
model counter is not linearizable: start(()), then A: increment(),
B: increment() and C: nothing at the same time: no order of the parallel
calls agrees with the model (A: increment() returned 1; B: increment() returned 1)
```

Generation, shrinking and the order of the cases are identical on every
target for the same seed (`LAWSPEC_SEED`).

## Collections

A model can say it behaves like one of the built-in collections. Each command
names the collection operation it implements, and LawSpec supplies the
reference definitions:

```lawspec fragment
model queue :: shared WorkQueue behaves like Queue Int32 is
  start newQueue
  offer as offer
  poll as poll          -- Maybe Int32
  queueSize as size
end
```

| Collection | Operations |
| --- | --- |
| `Queue a` | `offer`, `poll`, `peek` |
| `Stack a` | `push`, `pop`, `peek` |
| `Deque a` | `pushFront`, `pushBack`, `popFront`, `popBack`, `peekFront`, `peekBack` |
| `Set a` | `add` and `remove` (whether it changed), `contains` |
| `KeyVal k v` | `put`, `remove` and `putIfAbsent` (the previous value), `get`, `containsKey` |
| all | `size`, `isEmpty` |

A model's start may leave its state out; it starts empty. Results compare by
value, so `size` may return any integer type.

Sets and maps are checked **key by key**, because operations on different
keys are independent. A large history then costs no more than its busiest
key.

## Handles

A `handle` is a type whose values only adapters create, such as a library's
concurrent queue. LawSpec passes a handle along unopened. It never generates,
builds or inspects one, and two handles are equal only when they are the same
value.

```lawspec fragment
handle Jobs

newJobs :: Unit -> Jobs
submit :: Jobs -> Int32 -> Unit
take :: Jobs -> Maybe Int32
```

A model's command arguments cannot be handles, and a law cannot quantify over
one. An adapter taking or returning a handle keeps its contract checks but
gets no contract law.

With [native bindings](../native-bindings.md), a handle can be the target's
own type, and commands can call its methods directly, with no adapter code.
For example, `Jobs` can bind to `java.util.concurrent.ConcurrentLinkedQueue`
with `submit` as its `offer` method. A Unit result discards the method's
return value. A `Maybe` result treats the target's null value as `Nothing`.

## Evidence

`lawspec evidence` lists each model as property-tested against its
reference, and a shared model's histories as property-tested for
linearizability.

The [models example](../../../examples/specs/models.lawspec) has a linear
stack and a shared counter. The [concurrent collections
example](../../../examples/specs/concurrent_collections.lawspec) checks a
queue, a set and a map built from each target's concurrent structures.
