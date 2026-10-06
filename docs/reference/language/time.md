# Time and the clock

Laws about time (`eventually within 2 s, P`, budgets such as `takes at most
5 ms`) are on [time in laws](temporal.md).

`lawspec.time` holds [durations](durations.md) and, when a unit imports it,
the clock: the `Instant` type, the `Clock` ability, and the virtual clock.
It is one of the [built-in abilities](builtins.md).

```lawspec
unit guide.clock

import lawspec.time (Instant, advance)

-- When a lease ends: now plus its length.
definition leaseEnd (length :: Duration where length <= 24h) :: Instant uses Clock is now + length end

-- Under the virtual clock, time moves only when told to.
law `a lease lasts its length` using virtual clock is
  definition is
    `for all` (length :: Duration where length <= 24h) .
      (let ends = leaseEnd length in advance length; now >= ends) = true
  end
end

-- A native adapter gets the clock as an argument.
stamp :: Int32 -> Instant uses Clock
```

## Instants

An `Instant` is a point in time: a whole number of microseconds since
1970-01-01T00:00:00Z, from 0 to the largest `Int64`. It is a wrapper over
`Int64`, so `valueOfInstant t` is its microseconds and `Instant n` makes one.

| Expression | Type | Meaning |
| --- | --- | --- |
| `t + d`, `d + t` | `Instant` | `d` after `t` |
| `t - d` | `Instant` | `d` before `t` |
| `b - a` | `Duration` | the time from `a` to `b` |
| `a < b`, `a <= b`, `a == b`, ... | `Bool` | comparisons |

Arithmetic on instants saturates rather than fails, so checked definitions
can use it freely: an instant before 1970 is 1970, one past the largest
`Int64` microsecond is that microsecond, and the time from a later instant
to an earlier one is no time at all.

## The Clock ability

```lawspec fragment
ability Clock is
  now :: Instant
  sleep :: Duration -> Unit
laws
  law `time does not go back` is ... end
  law `sleeping lets at least that long pass` is ... end
end
```

- `now` is the current instant.
- `sleep d` lets at least `d` pass.
- Every handler keeps two laws: two readings in a row never go back, and
  after `sleep d` the clock has moved on by at least `d`.

The **default handler** is the system clock, read once when the program
starts and moved on by the platform's monotonic clock since. It therefore
never goes back, even when the system clock is changed. `sleep` blocks the
calling thread.

## The virtual clock

`using virtual clock` runs a law under a clock that starts at 1970 and moves
only when the law, or the code it calls, sleeps. `advance d`, a definition
of `lawspec.time`, lets `d` pass: under the virtual clock it passes at once,
and under the system clock it sleeps.

The virtual clock is a spec handler, `virtualClock`, with the current
instant as its state. Laws under it are deterministic, and the compiler
evaluates them where their domain is finite.

## Native interfaces

| Target | `now` | `sleep` |
| --- | --- | --- |
| Python | `def now(self) -> data.Instant` | `def sleep(self, value0: timedelta) -> None` |
| JavaScript, TypeScript | `now(): data.Instant` | `sleep(value0: data.Duration): void` |
| Go | `Now() Instant` | `Sleep(value0 LawSpecDuration)` |
| Java | `lawspec.data.Instant now()` | `void sleep(java.time.Duration value0)` |
| Kotlin | `fun now(): lawspec.data.Instant` | `fun sleep(value0: kotlin.time.Duration)` |
| Haskell | `now :: IO Data.Instant` | `sleep :: Data.Duration -> IO ()` |
| Rust | `fn now(&self) -> Instant` | `fn sleep(&self, value0: std::time::Duration)` |
