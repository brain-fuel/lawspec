---
id: lawspec.reference.language.models
kind: reference
title: Stateful models
---
# Stateful models

A model is an ability whose reference is a stateful spec handler; checking
it checks the native handler against that spec handler through
`abstract`. See [existing features as abilities](abilities-mapping.md#models).

A `model` pairs a system's commands with a simpler reference: a model state
and a checked definition for each command. LawSpec generates sequences of
commands, runs them against your adapters, and checks every result and state
against the reference. For a shared model it also runs commands at the same
time and checks that every history is linearizable ref:herlihy-wing-linearizability, with the search of Wing and Gong ref:wing-gong-linearizability.

```lawspec fragment
model stack :: Stack n by List Int8 is
  start empty by Nil
  push by modelPush
  pop by modelPop
  abstract toList
end model
```

## Declaring a model

```text
model name :: [shared] State by Model is
  start command by value        -- or ~ value
  command by reference [when precondition]
  abstract function
  invariant predicate
end model
```

| Line | Meaning |
| --- | --- |
| `start f by e` | `f` makes the first system state. `e` is the first model state: a value when `f` takes `Unit`, otherwise a definition taking the same arguments. |
| `cmd by ref` | `cmd` is an adapter of the system. `ref` is a checked definition taking the command's other arguments, then the model state, and returning `Pair result next` (or the next state alone when the result is `Unit`). |
| `when p` | The command runs only when `p model` holds. |
| `abstract f` | `f` turns the system state into a model state, and must equal the model's at every step. |
| `invariant p` | `p` holds of the model state, or of the system state, after every step. |
| `consistency c` | How a shared model's parallel histories must agree with the model: `linearizable` (the default), `sequential`, `causal` or `eventual`. See [consistency](#consistency). |

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
end model
```

## Laws about runs

A law can claim something about every run of a model, or about some run. It
is checked over the model itself: its start, each command's reference and
precondition. It never runs the native implementation; that is the model's
conformance check, with its own evidence.

```lawspec
unit guide.order_runs

type Stage is one of
  | Received
  | Paid
  | Shipped
  | Cancelled
end type

type Order is a record{ id :: Int32 } end type

newOrder :: Unit -> Order
pay :: Order -> Unit
retry :: Order -> Unit
ship :: Order -> Unit
cancel :: Order -> Unit

function toPaid (s :: Stage) -> Stage is Paid end function
function stay (s :: Stage) -> Stage is s end function
function toShipped (s :: Stage) -> Stage is Shipped end function
function toCancelled (s :: Stage) -> Stage is Cancelled end function
function isReceived (s :: Stage) -> Bool is s = Received end function
function isPaid (s :: Stage) -> Bool is s = Paid end function
function isShipped (s :: Stage) -> Bool is s = Shipped end function
function isCancelled (s :: Stage) -> Bool is s = Cancelled end function

model orders :: shared Order by Stage is
  start newOrder ~ Received
  pay ~ toPaid when isReceived
  retry ~ stay when isReceived
  ship ~ toShipped when isPaid
  cancel ~ toCancelled when isReceived
end model

property "|nothing ships unpaid| is
  never isShipped before isPaid
end property

property responds (p) with (q) is
  whenever p, eventually q
end property

law "|nothing ships unpaid| in model orders is
  definition: every run holds "|nothing ships unpaid| end definition
end law

law "|paid orders ship| in model orders assuming fairness for ship is
  definition: every run holds responds isPaid with isShipped end definition
end law

law "|an order can ship| in model orders is
  definition: some run holds eventually isShipped end definition
end law
end unit
```

A `property` names a claim about runs. Its words are plain:

| Form | Holds on a run when |
| --- | --- |
| `always P` | `P` holds at every step |
| `eventually P` | `P` holds at some step |
| `whenever P, Q` | at every step where `P` holds, `Q` holds from there |
| `never P before Q` | `P` does not hold before the first step where `Q` holds |
| `P until Q` | `Q` holds at some step, and `P` at every step before it |
| `P implies Q`, `P and Q`, `P or Q`, `not P` | as in logic |

An atom names a `Bool` function of the model state. A property may take
parameters between its words, as `responds (p) with (q)` does, and a law
or another property uses it with its words and arguments. A property is also
named by its quoted name.

A law in a model says `every run holds P` or `some run holds P`. A run that
ends stays in its last state. `assuming fairness for c` (weak fairness)
considers only runs where a command `c` that stays enabled is taken;
`assuming strong fairness for c` considers only runs where `c`, enabled again
and again, is taken.

Every reachable state is explored, with each command's arguments drawn from
their finite types. The law is `proved` when no run breaks it (or a run holds
it), and the reason says how many states were explored. It is `refuted` with
the run that breaks it, written as its commands, with the steps that repeat in
parentheses: `validate, decline, (decline)`. A model with more states than the
search explores is `incomplete`: "no counterexample in the first 20000
states". The check runs when the `proof`, `exhaustive` or `model` layer is
selected.

### Deadlines

`whenever P, Q within d` says that after a state where `P` holds, `Q` holds
within `d`; `Q within d` counts from the start. Time is whole microseconds,
as for `Duration`, and passes in ticks: the tick is the greatest common
divisor of `d` and one hour (an hour for `within 24h`, 30 minutes for
`within 90min`). Commands
take no time. Time passes only through the model's explicit `wait` command,
one tick at a time, so its precondition says when time may pass. A model
without `wait` reports its deadline unsupported. A deadline met at exactly `d` is met.
A run that misses it is shown with the time it waited: `authorize, wait 25h`.

### Unbounded models

A model whose states cannot all be explored leaves a law incomplete. For a
law of the form `every run holds always P`, `lawspec prove` then asks Z3:

- **By induction.** `P` holds of every first state, and every command keeps
  it. Each is its own task. When all hold, the law is proved.
- **By an invariant.** When `P` alone is not kept, Z3's Spacer may propose a
  stronger condition. LawSpec never trusts it as given: plain queries check
  that it holds at the start, that every command keeps it, and that it implies
  `P`. Only then is the law proved, and the reason shows the invariant.
- **By a bounded run search.** Z3 looks for a run of up to 8 steps that breaks
  `P`. The reference evaluator replays it, step by step, before the law is
  refuted with that run.


## Laws about histories

A law can also judge an observed history: entries in order, from a checked
definition that takes `Unit`. Atoms are predicates of one entry.

```lawspec fragment
law "|nothing used after revocation| in history today is
  definition: the history so far holds whenever isRevoked, always not isUse
  end definition
end law
```

`the complete history holds P` says the history is closed: nothing more
happens, and the law is proved or refuted. `the history so far holds P` says
more may come, so the law has three outcomes, as in LTL3 (Bauer, Leucker and
Schallhart):

| Status | When |
| --- | --- |
| `proved` | No continuation could break it |
| `refuted` | No continuation could keep it; the reason names the entry where it broke |
| `pending` | What comes next decides; the reason says whether it holds so far |

A deadline, `whenever P, Q within d`, reads each entry's time from its field
`at`, a `Duration`. It is refuted as soon as an entry is observed past the
deadline with no `Q` before it.

An invariant of a model (`every run holds always P`), a property of a bounded
history, and a requirement on the unbounded future are different claims, and
their evidence says which: a model law covers every run; a complete history
covers its entries; an open history is `pending` while the future decides.

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

### BEAM model tests

Erlang, Elixir and Gleam run the portable model checker through EUnit,
ExUnit and Gleeunit. Generated test names include the model's name and
whether the run is sequential or parallel. A failure reports the seed,
case and reduced command sequence.

`lawspec test` includes these checks alongside the unit's laws. Sequential,
parallel and scenario checks have separate identities, cached results and
failed seeds. Normal native test discovery runs each check once.

Adapters use the production handlers for their declared abilities. Each
replay, including a shrink attempt, gets a fresh handler scope and workflow
test context. Async adapters return ordinary native values to the checker.
Actor models run their handlers in persistent `gen_server` processes under
an owned OTP supervisor; an injected crash replaces the worker and runs
the declared restart adapter. The supervisor is closed after the case.

The BEAM checker requires `abstract` for an eventual model so it can compare
the final state. It partitions linearizable collection histories by key;
sequential and eventual histories retain each caller's order across keys.

## Consistency

Replicated and distributed systems often promise less than
linearizability. A shared model can say what it promises:

```lawspec fragment
model views :: shared Views by Int64 is
  consistency eventual
  start newViews ~ 0
  hit ~ modelHit
  abstract total
end model
```

| Consistency | Every history must have... |
| --- | --- |
| `linearizable` (the default) | one order of all the calls that keeps real time (a call comes after every call that returned before it began) and gives every result the model gives. |
| `sequential` | one order that keeps each thread's own order, and what its messages carried, and gives every result. Real time between threads does not count. |
| `causal` | for each thread, an order of what it could have seen (its own calls, and those that happened before them, through its own order or messages) that gives that thread's results. Different threads may see different orders. |
| `eventual` | once every call is done, the abstracted state of some order of all the calls. Results are not checked. Use `abstract`, so there is a state to compare. |

Each is weaker than the one above it. In a [scenario](scenarios.md), "happened
before" follows messages: a call before a send happened before every call
after the matching receive.

The [consistency example](../../../examples/specs/consistency.lawspec) has
a page-view counter with one replica per caller. Callers see stale counts,
so it is neither linearizable nor causal, but every hit is counted in the
end: it is eventually consistent. A version that loses hits is rejected.

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
end model
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
return value. A `Maybe` result treats the target's null value as `Absent`.

## Evidence

Select `"model"` in `verification.layers` to generate and run model,
parallel-history, scenario and supervision checks. This selection is independent
of ordinary law properties and examples. Omitting it preserves the typed model,
reference definitions and public actor, supervisor and session APIs. Mandatory
definition validation still checks reference code.

`lawspec evidence` distinguishes checks that are planned from checks that have
completed. An unselected model check reports `not-verified`; selecting the layer
alone supplies no completed evidence. Native checks compare sampled executions
against the reference and its consistency requirements. Their success does not
prove every history or establish that a different native implementation conforms.

Every target registers its model checks in the native test manifest. Some native
frameworks combine a model's sequential, parallel and scenario checks in one
method. Its successful completion covers those included checks together; a
failure cannot be recorded as a successful completion of any of them.

The [models example](../../../examples/specs/models.lawspec) has a linear
stack and a shared counter. The [concurrent collections
example](../../../examples/specs/concurrent_collections.lawspec) checks a
queue, a set and a map built from each target's concurrent structures.

## State-dependent argument domains

Linear command argument refinements may refer to the state's index
ref:DEC-dependent-model-arguments. Bind the indexed state before arguments that
use its index, as required by ordinary indexed input elaboration:

```lawspec fragment
chooseAt :: Stack n / Stack n -> (i :: Int8 where i >= 0 && i < n) -> Int8
```

The existing indexed-family elaborator replaces the implicit `n` with its
checked structural measure. Model generation instantiates that measure from the
current abstract run's typestate indices. After each reference transition it
recomputes the domain; it never reads the native implementation to choose test
inputs. Reference state values, guards and declared index transitions jointly
control generation. A reference model must faithfully relate its abstract state
to those declared indices; testing against that model does not establish its
fidelity to the product.

At index zero, `0 <= i < n` is provably empty, so `chooseAt` is disabled. At index
two it admits 0 and 1. Finite model checking enumerates the domain at each
reachable state. Sampled native model tests draw from that range and retain
sampled meaning. Shrinking replays the reference and validates every later
argument against its new domain before executing the candidate.

The implemented fragment is integer bounds using `<`, `<=`, `>`, `>=` and `=`,
with constants and state indices combined by addition, subtraction and
multiplication. Ordinary type bounds are intersected with these restrictions.
Non-interval dependent predicates and dependent algebraic-data generators remain
explicitly unsupported. Enumeration limits are incomplete. If a generated
dependent argument is rejected by an otherwise enabled reference command, its
bounded attempt is incomplete and cannot pass as an empty domain. Shared models
remain unindexed; no `Fin` primitive or OTP `gen_statem` adapter is added.

### Precedents and trust boundary

| Primary source | Mapping to LawSpec |
| --- | --- |
| [PropEr proper_statem](https://proper.hexdocs.pm/proper_statem.html) and [implementation](https://github.com/proper-testing/proper/blob/master/src/proper_statem.erl) | Generate commands from the abstract state, advance the reference, and revalidate shrunk sequences. LawSpec retains its portable seeded generators and runtime callbacks instead of introducing a separate state machine framework. |
| [Idris Data.Fin](https://idris-lang.org/Idris2/base/docs/Data.Fin.html) and [implementation](https://github.com/idris-lang/Idris2/blob/main/libs/base/Data/Fin.idr) | `Fin n` illustrates a finite domain below a bound, including an uninhabited zero case. Existing integer refinements express that domain here; no primitive is needed. |
| [SPARK contracts](https://docs.adacore.com/spark2014-docs/html/ug/en/source/how_to_write_subprogram_contracts.html) and [Why3 VC generation](https://why3.org/doc/vcgen.html) | Preconditions define applicability; generating an obligation and discharging it are distinct. Argument generation is not solver discharge. |
| [Lean verification conditions](https://lean-lang.org/doc/reference/latest/The--mvcgen--tactic/Verification-Conditions/) and [Rocq induction](https://docs.rocq-prover.org/master/refman/proofs/writing-proofs/reasoning-inductives.html) | Proof goals and checked proof terms have separate roles. This work does not integrate either proof kernel or add a proof tier. |

The small descriptor extension translates already elaborated integer comparisons
and evaluates their bounds against reference indices. That translation, range
arithmetic, existing reference evaluator and sequence revalidation are trusted
for generated tests. Explicit-state completeness still requires every finite
argument tuple and reachable state to be explored. Existing Z3 evidence retains
its translation-and-solver trust boundary. Mandatory definition validation stays
independent of every optional law layer.
