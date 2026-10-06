---
id: lawspec.reference.language.durations
kind: reference
title: Durations
---
# Durations

A `Duration` is a whole number of microseconds, from 0 to
4,611,686,018,426,999 microseconds (about 146 years). That is the largest range
every target's native duration holds exactly, so a duration means the same on
every target.

```lawspec
unit guide.timeouts

-- The totality audit proves the result is in range for every retries.
definition timeoutFor (retries :: Int32 where retries >= 0 && retries <= 5) :: Duration is
  2s + 500ms * retries
end

remaining :: Duration -> Duration -> Duration

law `what remains of a budget` is
  definition is
    `for all` (budget :: Duration) (spent :: Duration) .
      prelude.toMicroseconds (remaining budget spent) =
        prelude.select (spent <= budget) (prelude.toMicroseconds budget - prelude.toMicroseconds spent) 0
  end
  example `part of a second` is
    budget = 1s
    spent = 250ms
    expect remaining budget spent = 750ms
  end
end
```

## Writing durations

A literal is a whole number followed by a unit, with no space and no sign:

| Literal | Unit | Constructor |
| --- | --- | --- |
| `5us` | microseconds | `prelude.microseconds n` |
| `250ms` | milliseconds | `prelude.milliseconds n` |
| `2s` | seconds | `prelude.seconds n` |
| `5min` | minutes | `prelude.minutes n` |
| `3h` | hours | `prelude.hours n` |
| `7d` | days | `prelude.days n` |

A literal beyond the range is a compile error. A constructor takes an
`Integer`, which must be non-negative and keep the result in range.
`prelude.toMicroseconds d` is the `Integer` number of microseconds in `d`.

## Arithmetic and comparison

| Expression | Result | Fails when |
| --- | --- | --- |
| `a + b` | `Duration` | the sum is beyond the range |
| `a - b` | `Duration` | `b` is longer than `a` |
| `d * n`, `n * d` | `Duration` | `n` is negative or the product is beyond the range |
| `prelude.quot d n` | `Duration`, rounded toward zero | `n` is not positive |
| `a < b`, `a <= b`, `a > b`, `a >= b` | `Bool` | never |
| `a == b`, `a != b` | `Bool` | never |

`n` is any integer type. Durations do not mix with numbers in `+` or `-`:
`1s + 1` is a type error.

An operation that leaves the range fails, as division by zero does: in a law,
the test fails; in a [checked definition](definitions.md), the totality audit
must prove it cannot happen. It uses the definition's refinements to do so.
`d + d` is accepted when `d` is refined by `d <= 1s`, and rejected when `d` is
unrestricted.

## Native types

| Target | Native type |
| --- | --- |
| Python | `datetime.timedelta` |
| Go | `time.Duration` (`LawSpecDuration` in generated code) |
| Java | `java.time.Duration` |
| Kotlin | `kotlin.time.Duration` |
| Rust | `std::time::Duration` |
| JavaScript, TypeScript | the generated `Duration` class, whose `value` is a `bigint` of microseconds |
| Haskell | the generated `Duration` record, holding an `Integer` of microseconds |

A native duration that is negative or has a fraction of a microsecond is not
a `Duration`. An adapter returning one fails; in Rust, which cannot report the
failure, the conversion panics.

## Internals

`Duration` and its operations live in a built-in unit, `lawspec.time`, which a
source receives when it uses a duration. Its operations are checked
definitions; each states its result exactly, so the totality audit can follow
durations through other definitions.

The [durations example](../../../examples/specs/durations.lawspec) uses each
form.
