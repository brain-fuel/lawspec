---
id: lawspec.reference.language.workflows
kind: reference
title: Workflows
---
# Workflows

A `workflow` names a pipeline of stages between state types. You write the
steps as adapters. LawSpec generates the workflow itself on every target, so
the steps are composed the same way everywhere. Callers use a workflow like
any other function.

```lawspec fragment
workflow placeOrder :: UnvalidatedOrder -> Either _ PricedOrder is
  validateOrder :: UnvalidatedOrder -> Either ValidationError ValidatedOrder
  all accumulate
    then checkStock
    then checkCredit
  end
  combine reserve
  priceOrder :: Reservation -> Either PricingError PricedOrder
    retry exponential 100ms 2 5 max 2s jitter full when isTransient
    timeout 2s
    circuitBreaker 5 30s cooldown 1min
    compensate releaseStock
  orElse quoteFallback
end
```

[Domain modeling](domain-modeling.md) shows how workflows fit with wrappers
and state types.

## Stages

Each line of the body is a stage, written as a keyword or as a symbol:

| Stage | Symbol | Meaning |
| --- | --- | --- |
| `f :: A -> B` | | a step: an adapter declared in place |
| `then f` | `>>= f` | a step declared elsewhere (`then f :: A -> B` also declares it) |
| `map f` | `<$> f` | apply a function that cannot fail to the state |
| `mapError g` | `<!> g` | map the error of the stage before it |
| `tap f` | | call `f` on the state for its effect; the state passes through |
| `ensure p else f` | | fail with `f state` unless `p state` holds; `f` is a checked definition |
| `orElse h` | `<\|> h`, `recover h` | on failure, continue with `h error :: Either E A` |
| `fallback h` | `?? h` | on failure, succeed with `h error :: A` |
| `all [accumulate] … end combine f` | | run steps on the same state and combine their results |

A step, `tap` or `map` function takes one input. A step or `tap` function that
returns `Either E T` can fail; the others cannot. `map`, `tap`, `ensure`,
`orElse`, `fallback` and `combine` may name an adapter or a [checked
definition](definitions.md).

The compiler checks that:

- each stage accepts the state the previous stage produces;
- the workflow's declared result is `Either E T` if any stage can fail, and `T`
  otherwise;
- every failure is an `E`.

Errors name the stage and the mismatched types.

### All groups

An `all` group lists steps, each written `f :: A -> B` or `then f`. Every step
takes the same state. `combine f` receives their results in the order the steps
are declared, so `combine` takes one argument per step:

```lawspec fragment
definition firstName (a :: Signup) (b :: Signup) :: Text is nameOf a end

workflow vet :: Signup -> Either _ Text is
  all accumulate
    then checkName
    then checkAge
  end
  combine firstName
end
```

Without `accumulate`, the group fails with its first failing step's error.
With `accumulate`, every step runs, and the group fails with all of their
errors. With a generated error type, those errors go into a `<Workflow>Failures`
constructor, which holds a list of the workflow's errors (`VetFailures`).

When a group has an [asynchronous](async-functions.md) step, its steps run at the same
time, so the group takes as long as its slowest step rather than all of them
together. Each target uses its own concurrency: threads in Python, `Promise`s
in JavaScript and TypeScript, goroutines in Go, virtual threads in Java and
Kotlin, scoped threads in Rust, `forkIO` in Haskell, and monitored BEAM processes
in Erlang, Elixir and Gleam. Results and errors keep
the order of declaration, not the order the steps finish in. Every step
finishes before the group reports a failure, and without `accumulate` that
failure is the first failing step's in declaration order.

A group whose steps are all synchronous runs them in turn. A synchronous call
blocks the thread that makes it, so running such steps side by side would put
each on a thread of its own, and every adapter would have to be safe to call
from any thread. The [approvals example](../../../examples/specs/approvals.lawspec)
checks that two slow checks take as long as the slower one.

## Error types

With a declared error type, as in `Either OrderError PricedOrder`, every stage
that can fail must fail with that type, or be followed by `mapError` with a
function into it.

With the error written as `_`, as in `Either _ PricedOrder`, LawSpec generates
a sum type named after the workflow, such as `PlaceOrderError`. It has one
constructor per stage that can fail, named after the workflow and the stage:
`PlaceOrderValidateOrderFailed` holds `validateOrder`'s error, and so on.
Constructor names are unique within a unit, so two workflows that share a step
get distinct constructors. Policies that can fail add constructors too (see
below): `PlaceOrderTimedOut`, `PlaceOrderRateLimited`,
`PlaceOrderCircuitOpen` and `PlaceOrderSaturated`.

## Policies

Policies follow a step on lines of their own. They govern how the step is
called. Durations are [duration literals](durations.md) such as `250ms` or
`2s`.

| Policy | Form | Fails with |
| --- | --- | --- |
| Retry | `retry <strategy> [jitter <kind>] [when p]` | the last attempt's error |
| Timeout | `timeout d [else e]` | `TimedOut` |
| Rate limit | `rateLimit <kind> n per (wait [max d] \| reject) [else e]` | `RateLimited` |
| Circuit breaker | `circuitBreaker n window cooldown d [else e]` | `CircuitOpen` |
| Bulkhead | `bulkhead n (wait [max d] \| reject) [else e]` | `Saturated` |
| Cache | `cache ttl` | |
| Compensation | `compensate undo` | the original error |
| Hedge | `hedge d [max n]` | the last attempt's error |

With a declared error type, a policy that can fail names the value its failure
becomes after `else`, as in `timeout 2s else Slow`. With a generated error
type, the failure gets its own constructor. Leaving out `else` for a declared
error type is a compile error.

`timeout` and `hedge` need an asynchronous step (an `async` adapter). A
synchronous call cannot be interrupted, and two synchronous calls cannot run
side by side.

### Retry

The strategy sets the number of attempts, counting the first, and the wait
before each further attempt k (2 or more):

| Strategy | Wait before attempt k |
| --- | --- |
| `immediate n` | none |
| `fixed d n` | `d` |
| `linear d step n` | `d + step * (k - 2)` |
| `exponential d factor n [max cap]` | `d * factor^(k - 2)`, at most `cap` |
| `fibonacci d n` | `d * fib(k - 1)`, where `fib(1) = fib(2) = 1` |
| `custom f [n]` | what `f` decides |

`custom f` names a checked definition
`f :: Integer -> E -> Duration -> RetryDecision`. It takes the next attempt's
number, the error, and the previous wait (`0us` at first). It returns
`RetryAfter d` to wait `d` and try again, or `Stop`. With `n`, at most `n`
attempts are made.

Jitter randomizes the waits:

- `jitter full` waits a random time between 0 and the wait;
- `jitter equal` waits half the wait plus a random time up to the other half;
- `jitter decorrelated` waits a random time between the first wait and three
  times the previous wait, at most the wait.

`when p` retries only errors for which the checked definition
`p :: E -> Bool` holds. Timeouts are retried too; the other policy failures
are not.

### Timeout

`timeout d` fails an attempt that has not finished within `d`, measured on
the workflow's clock (see [running workflows](#running-workflows)). With
`retry`, each attempt has its own timeout.

### Rate limit

`rateLimit <kind> n per` admits `n` calls per `per`:

| Kind | Admits |
| --- | --- |
| `tokenBucket` | bursts of up to `n`, refilled evenly over `per` |
| `leakyBucket` | one call every `per / n`, each waiting its turn |
| `fixedWindow` | `n` calls in each window of length `per` |
| `slidingWindow` | `n` calls in any span of length `per` |

When the limit is reached, `wait` waits until a call is admitted, and
`wait max d` waits at most `d`. `reject` fails at once.

### Circuit breaker

`circuitBreaker n window cooldown d` opens after `n` failures within `window`.
While it is open, calls fail at once for `d`. Then one trial call is let
through. If it succeeds, the breaker closes; if it fails, the breaker opens
again.

### Bulkhead

`bulkhead n` admits at most `n` calls of the stage at once. Beyond that,
`wait` and `reject` behave as for a rate limit.

### Cache

`cache ttl` reuses a successful result for the same input for `ttl`. Inputs
are compared by value. Failures are not cached.

### Compensation

`compensate undo` names an adapter or checked definition `undo :: B -> T` over
the step's success value. If a later stage makes the workflow fail, the
completed stages' undos run, last completed first. The workflow still fails
with its original error. A stage that never succeeded is not undone.

### Hedge

`hedge d` starts a second attempt when the first has not succeeded after `d`,
and keeps the first success. With `max n`, up to `n` attempts start, `d` apart.
If every attempt fails, the stage fails with the last failure.

### Order

A stage with several policies checks its cache first, then passes its breaker,
rate limit and bulkhead, in that order. Its attempts then run, each under the
timeout and hedge, with retries between them. Only the outcome of the whole
retried call counts toward the breaker.

## Running workflows

A workflow runs under a *workflow runtime*. The runtime holds a clock, a seeded
random source for jitter, a trace of what happened, and the state of the
stateful policies: limiters, breakers, bulkheads and caches. Calling a
workflow without a runtime uses one shared, process-wide runtime with the real
clock.

To give a workflow its own state, or a virtual clock, create a runtime and
pass its context where the workflow takes its Symbol context:

| Target | Runtime | Context |
| --- | --- | --- |
| Python | `ls.WorkflowRuntime(clock=None, seed=0)` from `lawspec_runtime` | `runtime.context()` |
| JavaScript, TypeScript | `new WorkflowRuntime(clock, seed)` from `lawspec_runtime` | `runtime.context()` |
| Go | `NewLawSpecWorkflowRuntime(clock, seed)`; a nil clock is real time | `runtime.Context(nil)` |
| Java, Kotlin | `new LawSpecRuntime.WorkflowRuntime(clock, seed)`; a null clock is real time | `runtime.context(new HashMap<>())` |
| Rust | `ls::WorkflowRuntime::new(Box::new(ls::RealClock::default()), seed)` | `ls::Context::with_workflow(runtime)` |
| Haskell | `LS.newWorkflowRuntime LS.realClock seed` | `LS.workflowContext runtime` |

A virtual clock (`VirtualClock`) starts at 0. Waiting advances it at once, so
retries and rate limits take no real time. Timeouts and hedges count virtual
time too: an attempt takes the time that passes on the clock while it runs, so
on a virtual clock an attempt that does not wait on the clock takes none, and
a hedged attempt starts when the one before it fails.

Workflow time is the `Clock` ability's (see [existing features as
abilities](abilities-mapping.md#workflows-and-policies)). The policies are
handler transformers over `Async`, `Clock` and `Fail`. When a law installs a
`Clock` handler, as `using virtual clock` does, the shared runtime runs its
workflows on that handler; a runtime you create keeps its own clock.

The trace lists events in order. Each event has a kind, a stage, and a number:

| Kind | Number |
| --- | --- |
| `start`, `finish` | the attempt |
| `sleep` | the wait between attempts, in microseconds |
| `wait` | the wait for a rate limit or bulkhead, in microseconds |
| `cached` | 0 |
| `compensate` | 0 |
| `hedge` | the attempt started beside the first |

### Asynchronous workflows

A workflow is asynchronous where its steps are. On JavaScript and TypeScript,
a workflow that calls an `async` step, directly or through another
definition, is an `async` function returning a `Promise`. On the other
targets, a workflow waits for its asynchronous steps and returns their
results directly, as checked definitions do (see [async
functions](async-functions.md)).

## Laws

The compiler adds laws that every target's generated workflow must pass:

- `<workflow> composes its stages`: the workflow equals the composition of its
  stages;
- `<workflow> succeeds when every stage does`, for a workflow that can fail and
  has no recovery;
- `<workflow> stops when <step> fails`, for each stage that can fail and has no
  later recovery: the workflow fails with that stage's error, mapped and
  wrapped as the workflow's error type;
- `<workflow> recovers with <h>`, for each `orElse` and `fallback`.

These laws check the generated code. Your own laws and examples check the
steps. A step declared again with the same type is shared between workflows.

Generated tests run workflows under a runtime with a virtual clock. In it, the
stateful policies (rate limits, breakers, bulkheads and caches) are off: a
workflow law calls both the workflow and its composition, which would
otherwise see each other's state. Retries, timeouts and hedges apply, on the
virtual clock, so they are deterministic. LawSpec checks every target's policies against the
reference models in the built-in `lawspec.resilience` unit instead. To test a
policy yourself, create a runtime in an adapter and call the workflow under it,
as the [resilience example](../../../examples/specs/resilience.lawspec) does.

## Internals

The rate limits, breaker and bulkhead are state machines written once in
LawSpec, in the built-in unit `lawspec.resilience`. They are generated to every
target like any checked definition, and each target's runtime drives them, so
they behave the same everywhere. A source receives the unit when its
workflows use a policy that can fail.

The [workflows example](../../../examples/specs/workflows.lawspec) uses every
kind of stage and both kinds of error type. The [limits
example](../../../examples/specs/limits.lawspec) uses rate limits,
compensation, timeouts and hedges.
