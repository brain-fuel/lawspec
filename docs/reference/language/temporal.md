---
id: lawspec.reference.language.temporal
kind: reference
title: Time in laws
---
# Time in laws

Some claims are about time: a deadline passes, a value stays in range for a
while, a call is quick. LawSpec writes them as propositions over the
`Clock` ability of [`lawspec.time`](time.md), so a law about time holds for
every lawful clock, and a law that needs control says so with `using
virtual clock`.

```lawspec
unit guide.temporal

import lawspec.time (Instant)

definition deadline (wait :: Duration where wait <= 1h) :: Instant uses Clock is now + wait end

law `a deadline passes` using virtual clock is
  definition is (let d = deadline 1s in eventually within 2 s, now >= d) = true end
end

law `nothing is late before its deadline` using virtual clock is
  definition is (let d = deadline 3s in always within 2 s, now < d) = true end
end

law `never past a later deadline` using virtual clock is
  definition is (let d = deadline 3s in never within 2s, now >= d) = true end
end

definition double (n :: Int32) :: Int64 is n * 2 end

law `doubling is quick` is
  definition is `for all` (n :: Int32) . double n takes at most 5 ms end
  example `one` is
    n = 1
    expect double n takes at most 5 ms
  end
end
```

A source that uses these imports `lawspec.time`.

## Temporal propositions

| Form | Holds when |
| --- | --- |
| `eventually within d, P` | `P` holds at some check before `d` has passed |
| `always within d, P` | `P` holds at every check until `d` has passed |
| `never within d, P` | `always within d, not P` |

- `d` is a duration literal: `2 s` or `2s`, `500 ms`, `1 min` (see
  [durations](durations.md)).
- `P` is a `Bool` expression. It extends as far as it can, so put the whole
  proposition in parentheses when something follows it.
- `P` is checked now, then after each of 20 equal sleeps of the clock, the
  last when `d` has passed. `eventually` stops at the first check that
  holds, and `always` at the first that does not.
- Each sleep is the `Clock`'s `sleep`, so the proposition uses `Clock`.
  Under the virtual clock a sleep passes at once: the checks are
  deterministic, and a law over checked definitions is evaluated by the
  compiler, which rejects one that is false. Under the real clock the checks
  take real time: a law that does not name a clock runs under every lawful
  one, the real clock first.

## Performance budgets

`e takes at most d` evaluates `e` between two readings of the clock and
holds when the time between them is at most `d`. It may stand as a law's
claim, or in an example, as `expect e takes at most d`.

- A budget is measured on the real clock, the `Clock` ability's production
  handler. A law with a budget runs under it alone, and may not name
  another clock.
- It is never proved, and the compiler does not evaluate it. Evidence
  reports it as **measured**, between property-tested and runtime-checked
  (see [evidence and discharge](evidence-and-discharge.md)).
- The time includes the call and the generated code around it, measured in
  the test process; keep budgets well above the times you expect, as
  machines vary.

## Limits

- The span of a temporal proposition is a literal, and the checks are 20
  equal steps of it.
- A temporal proposition watches what its expression can observe through
  abilities; processes of a [scenario](scenarios.md) are run by the
  scheduler, not by these propositions.
