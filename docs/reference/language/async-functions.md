---
id: lawspec.reference.language.async-functions
kind: reference
title: Asynchronous functions
---
# Asynchronous functions

`async` before a signature makes an adapter asynchronous: the implementation
returns its target's task, and the generated tests await it.

```lawspec
unit guide.orders

-- A product's price, looked up remotely. Prices are never negative.
async price :: (sku :: Text) -> (r :: Int32 where r >= 0)
async stock :: Text -> Int32
quote :: Text -> Int32

law `prices agree with quotes` is
  definition is `for all` (sku :: Text) . price sku = quote sku end
  example `a free sample` is
    sku = "free"
    expect price sku = 0
  end
end

law `stocked products have prices` is
  definition is `for all` (sku :: Text) . stock sku > 0 implies price sku >= 0 end
end
```

`async` is a keyword only before a signature's name; it remains usable as a
name elsewhere.

## As an ability

`async f ::` is the same declaration as `f :: ... uses Async`, with `Async`
from `lawspec.concurrent`: an adapter that uses `Async` runs on its default
handler, the target's native async, so its native code returns the target's
task and takes no handler for it. `lawspec check --json` lists `Async` in the
declaration's `uses`. See [existing features as
abilities](abilities-mapping.md#async).

```lawspec fragment
async price :: Text -> Int32
price :: Text -> Int32 uses Async     -- the same
```

## Per target

| Target | The adapter | How a test awaits it |
| --- | --- | --- |
| Python | `async def` (a coroutine) | `asyncio.run` |
| JavaScript, TypeScript | `async function`, a `Promise<T>` | `await`, in async properties |
| Java | returns `CompletableFuture<T>` | `join()` |
| Kotlin | `suspend fun` | `runBlocking` |
| Go | returns `lawspec.Task[T]`, made with `lawspec.Go(func() T { ... })` | `Await()`; a panic in the goroutine is raised again |
| Haskell | returns `IO T` | runs the action |
| Rust | `pub async fn`, a `Future` | the runtime's `block_on`; no executor crate is needed |

## Semantics

- Only adapters can be asynchronous. A checked definition cannot call an
  adapter, so it cannot call an asynchronous one.
- Each call is awaited where it is made, in the clause's left-to-right order.
  Pure adapters mean the same awaited or not.
- Contracts work as for other adapters: the arguments are checked before the
  call, and the awaited result against the refinement and postconditions. A
  task that fails fails the test.
- The evidence report gives an asynchronous adapter's obligations the stage
  `adapter`, with the reason "asynchronous adapter ...".

An asynchronous adapter can also be bound to existing native code that
returns the target's task; see
[native bindings](../native-bindings.md#async-adapters).

## Limits

- Calls in one clause are awaited one after another; they do not yet overlap.
- Long-lived concurrent components (actors, processes and supervision) are a
  separate, later feature.
