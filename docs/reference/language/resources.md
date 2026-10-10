---
id: lawspec.reference.language.resources
kind: reference
title: Resources
---
# Resources

A resource is something a law needs that lives outside the program: a store,
a directory, a port. A law takes resources as inputs. Each case of the law
acquires them first and releases them after, even when the case fails, so
every case starts afresh. Cleanup failures fail the run.

```lawspec
unit guide.resources

handle Store

openStore :: Unit -> Store
closeStore :: Store -> Unit
clearStore :: Store -> Unit
put :: Store -> Int32 -> Int32 -> Unit
size :: Store -> Int32

resource Store is
  acquire is openStore unitValue end
  release store is closeStore store end
  reset store is clearStore store end
end

law `every case gets an empty store` for store :: Store is
  definition is
    `for all` (k :: Int32) (v :: Int32) .
      size store = 0 and put store k v = unitValue and size store = 1
  end
end
```

## BEAM ownership and cancellation

On Erlang, Elixir and Gleam, each resource has a dedicated owner process.
That process runs `acquire`, `reset` (for shared resources) and `release`.
The test worker borrows the returned handle. A resource owner survives the
test worker, so a test timeout can stop the test and still attempt cleanup.
Nested resources are released in reverse acquisition order.

An adapter using process-private state must route operations to its owner.
For example, an Erlang adapter can save a private ETS table in the owner's
process dictionary and return `self()` as its handle. Operations use
`lawspec_beam_resource:call(Owner, fun() -> ... end)` to access the saved
table. `release` runs in the original owner and can delete the table
directly. Native LawSpec handles must be identity values (a PID, reference
or port). A handle that already supports use from another process needs no
such bridge.

Cleanup has a separate five-second allowance per resource for draining
borrowers and another five seconds for release. A callback that exceeds its
cleanup allowance is terminated and the run reports a cleanup failure.
Other resources still get their cleanup attempt. A failed or timed-out
cleanup cannot be accepted by `known failing` or retried into a passing run.
The native runner waits for surviving owners before finishing the suite.

An acquisition that never returns has not supplied a value to `release`.
Its adapter must handle any partially acquired external state. Forced
termination also cannot guarantee that an arbitrary release callback
finishes; the failure is reported explicitly.

## Declaring a resource

```lawspec fragment
resource Type is
  acquire is expression end
  release name is expression end
  reset name is expression end
end
```

- `Type` names a declared type, usually a [handle](models.md#handles).
- `acquire` gives a new value of the type. It usually calls an adapter.
- `release` frees the value it names. Its result is ignored.
- `reset` is optional. It readies a value for another case; the harness may
  use it to share one value between cases. Without it, nothing is shared.
- A unit declares at most one resource for each type.

## Taking resources

A law lists its resources after its handlers, before `is`:

```lawspec fragment
law `a note reads back` for dir :: TemporaryDirectory is ... end
law `two stores` using Gateway for a :: Store, b :: Store is ... end
```

- The law's definition and examples use each resource by its name, like an
  input the law does not quantify over.
- Each case acquires the resources in order, and releases them in the
  opposite order, whether the case passes, fails or throws.
- A law never releases a resource itself: a law that releases a resource
  it takes, directly or through a definition it calls, is an error, since
  it could use the resource after its release.
- The compiler never evaluates a law with resources; the generated tests
  check it.
- The check that a law never releases its resource is a conservative
  data-flow analysis over the whole program, not a flow type. A value is
  derived from a resource when it is the resource or is computed from it (a
  `let`, a `match` field, an element). A law is rejected when it passes a
  derived value to the release clause's adapter or ability operation, or to
  a checked definition or spec handler that may pass it on to one, through
  any chain of calls. It may reject a law whose releasing call never runs.
  Native adapters other than the release clause's own are opaque, and
  trusted not to release the resource.

## Sharing a resource

A [harness](harness.md#sharing-resources) may share one value of a resource
between cases, with `share R per group | unit | run`, only when the resource
declares `reset`. The law means the same: every case after the first gets
the value reset, so it never sees what another case left. At run time:

- the first case that takes the resource acquires it;
- every later case in the same scope waits until no other case holds it,
  then resets it and uses it;
- it is released when the test process ends (a Haskell unit's spec releases
  it when the unit's tests are done).

A harness that also says `parallel` runs cases at the same time, so it may
share only a resource declared concurrent:

```lawspec fragment
resource Scratch is concurrent
  acquire is Scratch 0 end
  release scratch is unitValue end
  reset scratch is unitValue end
end
```

`concurrent` says cases cannot interfere through the resource. A shared
concurrent resource is held by any number of cases at once, and reset only
when no case holds it. Sharing a resource that is not concurrent under
`parallel` is a compile error.

A `run` scope is one test process: targets whose runner starts a process per
test file (JavaScript and TypeScript under `node --test`) share per file.

## Built-in resources

These come with LawSpec, from the built-in unit `lawspec.resources`:

| Resource | Acquire | Release | Read it with |
| --- | --- | --- | --- |
| `TemporaryDirectory` | an empty directory | removes it, with everything in it | `directoryPath dir` |
| `TemporaryFile` | an empty file | removes it | `filePath file` |
| `FreePort` | a TCP port on the local host that was free | nothing | `portNumber port` |
| `SavedEnvironment` | a copy of the environment | restores it | nothing |

Each acquires and releases through [`lawspec.host`](host.md#resources)'s
abilities, under their production handlers, so binding another `FileSystem`,
`Environment` or `Ports` handler in `lawspec.json` changes how they do it.

`SavedEnvironment` lets a law change the environment through its adapters,
and puts it back afterwards. A JVM cannot change its process environment, so
on Java and Kotlin it saves and restores the system properties. Rust runs
tests on several threads, so there a `SavedEnvironment` also holds the
environment for its case alone.

## Native shape

| Target | How a case brackets its resources |
| --- | --- |
| Python | `try` ... `finally` |
| JavaScript, TypeScript | `try` ... `finally` |
| Go | `defer` |
| Java, Kotlin | `try` ... `finally` |
| Rust | `catch_unwind`, then release, then resume any panic |
| Haskell | `LS.withResource`, with `finally`; a built-in resource is acquired in `IO` |
