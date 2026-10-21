---
id: lawspec.reference.language.law-sets
kind: reference
title: Law sets
---
# Law sets

The laws about a function are also checked together. Each law can hold on its
own while the set is still wrong: an input may have no law, two laws may both
apply, or they may require different results. Four checks find these cases.

| Check | Stage | It fails when |
| --- | --- | --- |
| Completeness | `completeness` | Some input satisfies no law's assumptions |
| Overlap | `overlap` | Two laws apply to the same input |
| Conflict | `conflict` | Two laws apply to the same input and require different results |
| Vacuity | `vacuity` | No input satisfies a law's assumptions |

The checks are on for every function that has laws. A `laws for` block states
claims about the set, and excuses checks for a reason.

## Which laws are checked

A law is in the set of `f` when it says what `f` returns, as
`for all ... => [assumptions implies] f arguments = result` (or
`must be result`). The arguments and the result must not call `f`. The
assumptions may be joined with `and`. Other laws about `f`, such as laws that
relate two calls, or examples without `for all`, are not part of the set.
They keep their own evidence.

## How the checks run

With the `exhaustive` layer, the compiler checks every input when the
arguments have a finite domain within the `exhaustiveLimit`. A check that
holds is `exhaustively-checked`. A check that fails is `refuted`, with the
input, and the build fails.

Other inputs need Z3. `lawspec prove` sends the compiler's Z3 tasks to Z3.
Every input Z3 gives is run by the reference evaluator before it is reported.
An input the evaluator does not confirm is not reported as a counterexample;
the check stays `incomplete`. When Z3 finds no input, the check is `proved`.
That trusts the translation and Z3. When Z3 answers `unknown` or times out,
the check is `incomplete`.

## Claims and exemptions

```lawspec
unit guide.refunds

type Decision is one of
  | Approved
  | Review
end type

function triage (amount :: Whole) -> Decision is
  if amount <= 5000 then Approved else Review end if
end function

law "|triage approves amounts up to five thousand| is
  definition: for all (amount :: Whole) => amount <= 5000 implies triage amount = Approved end for all end definition
end law

laws for triage are
  partial because "amounts above 5000 go to manual review"
end laws

end unit
```

The block comes after the function. It names the function, and holds one item
per line:

| Item | Meaning |
| --- | --- |
| `complete over condition` | The laws cover every input where `condition` holds. The condition uses the function's parameter names. |
| `without overlap` | No two laws apply to the same input. This is checked anyway; the claim records it. |
| `without conflict` | No two laws require different results. This is checked anyway; the claim records it. |
| `partial [until V] because "reason"` | Excuses completeness. |
| `overlap allowed [until V] because "reason"` | Excuses overlap. |
| `conflict allowed until V because "reason"` | Excuses conflict. A conflict is excused only for a while, so `until` is required. |
| `vacuity allowed for "|law| [until V] because "reason"` | Excuses one law's vacuity. |

A claim and the exemption of the same check cannot both be written.

## Exempted checks

An excused check that fails is `exempted`, not `refuted`. The row keeps the
counterexample, the reason and the expiry. `lawspec evidence` lists it under
`EXEMPTED`, with for example `until 1.2.0 (project is 1.1.4)`. The build does
not fail. `exempted` is weaker than `assumed`.

`until` takes one of:

- a version, like `1.2.0`. It is compared with the package's `version` in
  `lawspec-package.json`, or with `projectVersion` in `lawspec.json`. A
  version without either is an error.
- a UTC date-time, like `2027-03-01T00:00Z` or `2027-03-01T00:00:00Z`. Other
  time zones are rejected.

At that version or time, the exemption expires. The check is `refuted` with
its counterexample, and the build fails. An exemption without `until` does not
expire.

## Precedent

The checks follow SPARK's `Contract_Cases`: completeness is "at least one case
holds", and disjointness is "at most one holds". Vacuity follows SPARK's and
Why3's smoke detectors. See [evidence and discharge](evidence-and-discharge.md)
for the statuses.
