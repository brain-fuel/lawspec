# Built-in abilities

LawSpec comes with abilities for the dependencies most programs share: time,
randomness, cryptography, files, the environment, ports, logs and
concurrency. Each lives in a built-in unit under `lawspec.`, has laws like
any [ability](abilities.md), and has a *default handler* on every target. A
program uses one by importing its unit.

| Unit | Abilities | Spec handlers | Page |
| --- | --- | --- | --- |
| `lawspec.time` | `Clock`, with `Instant` | `virtual clock` | [Time and the clock](time.md) |
| `lawspec.randomness` | `Random`, `SecureRandom` | `seeded random n` | [Randomness](randomness.md) |
| `lawspec.crypto` | `Hash`, `KeyExchange`, `Signature`, `Aead` | | [Cryptography](cryptography.md) |
| `lawspec.host` | `FileSystem`, `Environment`, `Ports` | `emptyEnvironment` | [Files, environment and ports](host.md) |
| `lawspec.logging` | `Log`, `Trace` | `silentLog`, `silentTrace` | [Logs and traces](logging.md) |
| `lawspec.concurrent` | `Async` | | below |
| `lawspec.network` | (the `Network` ability's secure handler) | | [Distribution](distribution.md#security) |

```lawspec
unit guide.builtins

import lawspec.time (Instant)
import lawspec.randomness

-- A deadline: now plus a wait. Under the virtual clock, time moves only
-- when told to.
definition deadline (wait :: Duration where wait <= 1h) :: Instant uses Clock is now + wait end

law `a deadline is as far off as the wait` using virtual clock is
  definition is
    `for all` (wait :: Duration where wait <= 1h) . (let d = deadline wait in d - now) = wait
  end
end

-- Seeded draws are reproducible: the same seed gives the same draws.
definition roll (sides :: Int64 where sides >= 1) :: Integer uses Random is randomBelow sides + 1 end

law `a seed fixes the rolls` is
  definition is
    `for all` (sides :: Int64 where sides >= 1) .
      handle roll sides with seededRandom end = handle roll sides with seededRandom end
  end
end
```

## Importing a built-in unit

`import lawspec.crypto` adds the unit to the program and brings its
abilities and spec handlers, as any import does. Its operations are called
like the unit's own (`sha3 m`, `now`); its types and definitions are
qualified by the alias (`crypto.Digest`) unless listed (`import lawspec.crypto
(Digest)`). A unit that does not import a built-in unit does not get it.

`lawspec.time` also holds [durations](durations.md), which every program that
uses them gets without importing it. Importing it adds the clock.

## Default handlers

Each built-in ability's production handler is its *default handler*: code in
the runtime of each target, generated into the built-in unit's module and
owned by the compiler. A law without `using` runs under it, then under each
spec handler, as for any ability.

- **Evidence.** Each built-in ability that a program uses reports one
  obligation with the status `default-handler` (`DEFAULT HANDLER` in the
  CLI): the handler is reviewed runtime code, its ability's laws are
  property-tested on it, and the cryptographic ones are checked against
  NIST's vectors. See [evidence and discharge](evidence-and-discharge.md).
- **Another handler.** `handlers` in `lawspec.json` binds a different
  production handler, as for any ability (see [handlers](handlers.md)):
  `{"ability": "lawspec.time::Clock", "native": [...]}`. The ability's laws
  then check the bound handler, and evidence reports it as assumed. The
  runtime offers one alternative: `SlhDsaSignatureHandler`, SLH-DSA for
  `Signature` (see [cryptography](cryptography.md)).
- **Native code** that uses a built-in ability gets its handler as an
  argument, typed by the ability's native interface, like any ability.

Where the default handlers live, by target:

| Target | Module | Example |
| --- | --- | --- |
| Python | `src/lawspec/<unit>.py` | `lawspec.time.ClockHandler()` |
| JavaScript, TypeScript | `src/lawspec/<unit>.mjs` or `.ts` | `new ClockHandler()` |
| Go | `lawspec/<unit>/adapter.go`, and a copy in each package that imports the unit | `NewClockHandler()` |
| Java | `src/main/java/lawspec/<Unit>.java` | `new lawspec.Time.ClockHandler()` |
| Kotlin | `src/main/kotlin/lawspec/<Unit>.kt` | `lawspec.Time.ClockHandler()` |
| Haskell | `src/Lawspec/<Unit>.hs` | `Lawspec.Time.clockHandler` |
| Rust | `src/lawspec/<unit>.rs` | `lawspec_time::ClockHandler::default()` |

Go keeps a copy of every ability a package uses in that package, so a
package that imports a built-in unit gets its default handlers in a
generated file, `lawspec_defaults_<unit>.go`.

## Dependencies of generated projects

The default handlers use each target's standard library where it has the
algorithm, and well-reviewed libraries elsewhere. Only a program that imports
`lawspec.crypto` or `lawspec.network` needs these libraries (in Haskell and
Rust, `lawspec.randomness` too: its secure generator is `crypton`'s, or
`getrandom`); the runtime and
every other built-in unit need none of them. `lawspec init` writes a project
without them, and its setup advice names them; add them when a program
imports either unit. (`directory` and `time` are Haskell dependencies of
every project.)

| Target | Dependencies |
| --- | --- |
| Python | `cryptography` 50 |
| JavaScript, TypeScript | `@noble/post-quantum` 0.7.1 |
| Go | Go 1.25 and `github.com/cloudflare/circl` v1.6.5 |
| Java, Kotlin | JDK 25 and `org.bouncycastle:bcprov-jdk18on` 1.86 |
| Haskell | `crypton` 1.1.5, `mlkem` 0.2.3.0, `mldsa` 0.1.1.0, `ram` 0.22.1 (Stack extra-deps) |
| Rust | `sha3` 0.12, `shake` 0.1, `ml-kem` 0.3.2, `ml-dsa` 0.1.1, `slh-dsa` 0.2.0-rc.5, `aes-gcm` 0.11.1, `getrandom` 0.4 |

## Async

`lawspec.concurrent` declares `Async`, whose one operation, `pause`, lets
other work run. Its default handler is each target's native concurrency:
`Thread.yield` on the JVM, `runtime.Gosched` in Go, `yield` in Haskell,
`std::thread::yield_now` in Rust, and a no-op in JavaScript, where a
handler's operations run synchronously. Natively it also starts functions as
tasks, waits for them, and runs several side by side; workflows use these.
`async f ::` is `f :: ... uses Async`: an [asynchronous
adapter](async-functions.md) runs on this default handler (see [existing
features as abilities](abilities-mapping.md#async)).

## Limits

- `temporary filesystem`, `environment with [...]` and `free port` as
  handler transformers, and built-in resources, are not built in yet; the
  file system's default handler works in the process's working directory.
- In Go every package holds every ability of the program, so when a
  program's own ability shares a name with a built-in one (`Log`, `Clock`,
  ...), Go names the program's after its unit: `example.shop`'s `Log` is
  `ExampleShopLog` there.
- Instants and durations saturate rather than fail: an instant before 1970
  is 1970, and the time from a later instant to an earlier one is none.
