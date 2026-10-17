---
id: lawspec.reference.language.evidence-and-discharge
kind: reference
title: Evidence and discharge
---
# Evidence and discharge

Every obligation in a program reports how it is discharged. The statuses, from
strongest to weakest:

| Status | API value | Obligations | How |
| --- | --- | --- | --- |
| `PROVED` | `proved` | Laws over checked definitions; definition postconditions and indices | Statically, by the prover |
| `EXHAUSTIVELY CHECKED` | `exhaustively-checked` | Laws whose inputs form a finite domain | Every input, by the compiler or the generated tests |
| `PROPERTY TESTED` | `property-tested` | Other laws | Generated cases, boundary cases and examples |
| `MEASURED` | `measured` | Performance budgets (`takes at most`; see [time in laws](temporal.md)) | Timed on the real clock by the generated tests; never proved |
| `RUNTIME CHECKED` | `runtime-checked` | Adapter contracts, definition preconditions, constructor constraints, native type bindings, non-linear definition indices | At every native boundary, or on each definition result |
| `DEFAULT HANDLER` | `default-handler` | The default handlers of built-in abilities (see [built-in abilities](builtins.md)) | Reviewed runtime code, its ability's laws property-tested, cryptography checked against NIST vectors |
| `ASSUMED / EXTERNAL` | `assumed` | Adapters, native functions, custom generators and codec hooks | Taken on trust |

A law's [harness](harness.md) decides how its tests run, never what the law
claims, so three more statuses come from the harness plane. The law stays an
obligation under each:

| Status | API value | Obligations | How |
| --- | --- | --- | --- |
| `KNOWN FAILING` | `known-failing` | Laws the harness marks `known failing` | Their tests must fail; a passing run fails and says so |
| `FLAKY` | `flaky` | Laws whose last run failed, then passed on a retry (`retry flaky`) | Read by `lawspec evidence` from the last `lawspec test` |
| `SKIPPED` | `skipped` | Laws the harness skips, and handler variants `test with` leaves out | Not run; the reason says why |

The reasoning behind these categories is in
[evidence and discharge](../../explanation/evidence-and-discharge.md).

## Planned and incomplete checks

`PLANNED` (`planned`) describes selected native checks awaiting execution.
`NOT VERIFIED` (`not-verified`) describes laws with no selected checks.
`INCOMPLETE` (`incomplete`) and `UNSUPPORTED` (`unsupported`) retain the reason
a search or analysis did not establish the obligation. None reports a completed
proof or native run. A bounded search miss does not prove nonexistence.

An attestation attached to a plan exposes `plannedAgainst`, separately from
completed execution's `against`. `lawspec evidence` can show the timestamp,
seed and environment of a historical passing native run while retaining the
current plan's status; this is not evidence that the current sources passed.

## Laws over checked definitions

Canonical authoring configuration selects law verification through
`verification.layers`; an empty selection leaves laws unverified. Intrinsic
definition admission remains mandatory. The following describes the compiler's
existing static proof procedure when selected. [The explicit Z3 host](../../explanation/smt-proof.md)
has its own documented encoding, execution evidence and trust boundary.

A law that calls only checked definitions is attempted as a proof: its claim
must follow from its input refinements by the exact linear arithmetic that
proves definition results. Definitions without preconditions are unfolded into
the claim. A definition with preconditions stays a call, and its arguments must
be shown to satisfy them.

```lawspec
unit guide.evidence

function twice (x :: Int32) -> Integer is x + x end function

law "|twice doubles| is
  definition :
    for all (x :: Int32) => twice x = x * 2 end
  end
end
```

`twice doubles` is proved.

A law over checked definitions that is not proved, but has a finite domain of
at most `exhaustiveLimit` inputs, is evaluated by the compiler for every input.
A counterexample is a compile error with code `refuted`. This law, over `Int8`,
is rejected:

```lawspec fragment
function twice (x :: Int8) -> Integer is x + x end function

law "|always positive| is
  definition:
    for all (x :: Int8) => twice x > 0 end
  end
end
```

```text
law always positive is false for x = -128
```

## Non-linear definition indices

A definition's result index that needs non-linear arithmetic, such as
`(r + r) * c = 2 * (r * c)`, cannot be proved by linear arithmetic. It is
checked on each result instead and reported as `RUNTIME CHECKED`, with the
reason "non-linear index arithmetic is beyond the prover; checked on each
result". A linear claim that does not follow is still a compile error.

## Laws over adapters

A law that calls an adapter is checked by the generated tests: every input of a
finite domain, or otherwise property testing. Its evidence names the adapters
it relies on. A law with no inputs has a single case and is exhaustively
checked.

Proved and compiler-checked laws are still emitted as tests, which check the
generated native definitions.

## Adapters and native code

An adapter is native code LawSpec cannot inspect. Its only evidence is the laws
that call it; an adapter that no law calls is reported as such. Native type
bindings decode values through checked codecs, so they are runtime-checked.
Native functions, custom generators and codec hooks are taken on trust,
although the values they produce are still validated.

## Obligation stages

Each obligation has a stage:

| Stage | Obligation | Status |
| --- | --- | --- |
| `law` | A law, with its claim as a Boolean expression | proved, exhaustively checked or property tested |
| `precondition`, `postcondition` | A contract of an adapter or definition | proved or runtime-checked |
| `construction` | A constructor field or wrapper constraint, checked whenever a value is built or decoded | runtime-checked |
| `adapter` | An adapter implementation | assumed |
| `binding` | A native type binding | runtime-checked |
| `codec`, `generator`, `native-function` | A codec hook, generator factory or bound native function | assumed |
| `handler` | A built-in ability's production handler: the runtime's default, or one bound in `lawspec.json` | default-handler, or assumed when bound |

## Where the tests ran

A law that runs under an ability's production handler, or calls an adapter,
is tested against whatever that dependency was wired to when the tests ran:
the real service, or a stand-in for it. An environment attestation records
which, and `lawspec evidence` reports it beside each law it touches.

An environment attestation is a versioned JSON document that any tool may
write: for one run in one environment, where each dependency was wired and
whether it was the real dependency or a stand-in.

```json
{
  "format": "environment-attestation",
  "version": 1,
  "environment": "staging",
  "run": {
    "id": "839f6cf4-02e4-4a52-971f-e1dbdca1d141",
    "started_at": "2026-10-09T19:30:31.606738Z",
    "recorded_at": "2026-10-09T19:30:33.153789Z"
  },
  "dependencies": [
    {
      "name": "shop.orders::Gateway",
      "endpoint": "localhost:9092",
      "reached": true,
      "kind": "stand-in",
      "stand_in": { "product": "acme/gateway", "version": "0.1.0", "conformance": "3" }
    },
    {
      "name": "shop.orders::normalize",
      "endpoint": "https://normalize.example.com",
      "reached": true,
      "kind": "real"
    }
  ]
}
```

| Field | Meaning |
| --- | --- |
| `format` | `"environment-attestation"`. |
| `version` | `1`. Another version is rejected; unknown fields are ignored. |
| `environment` | The environment's name, not empty. |
| `run.id` | The run's identity, not empty; compared, never parsed. |
| `run.started_at`, `run.recorded_at` | RFC 3339 times; `recorded_at` is not before `started_at`. |
| `producer` | Optional: the writing tool's `name` and `version`. Informative only. |
| `dependencies[].name` | The dependency, unique in the document. |
| `dependencies[].endpoint` | The endpoint it was wired to: `host:port` or a URL. |
| `dependencies[].reached` | Whether the writer reached the endpoint when it recorded the run. |
| `dependencies[].kind` | `real` or `stand-in`. |
| `dependencies[].stand_in` | Present exactly when `kind` is `stand-in`: the stand-in's identity (`product`), its `version` and the `conformance` level its maker declares, with an optional `history_digest`, a digest of the history it was recorded from. |

A dependency's `name` matches what a law relies on:

- an ability, by its resolved identity, `unit::ability::Name` or
  `unit::Name` (with its type arguments, if any, as the evidence spells
  them), when the law runs under that ability's production handler, directly
  or through the definitions it calls; a law under a spec handler does not
  touch the dependency;
- an adapter or bound native function, `unit::name`, that the law calls.

Each law obligation whose evidence comes from tests that ran (exhaustively
checked by its tests, property tested, measured or known failing) and that
relies on an attested dependency is reported with `environment`,
`environmentRun` and `against`, the dependencies it ran against. Its status
stays what it was:

```text
PROPERTY TESTED (2)
  law shop.orders::checkout charges the amount: checkout (cents)
    the generated tests check 100 generated cases, 4 boundary cases and 0 examples; relies on the native shop.orders::ability::Gateway handler
    ran in environment staging (run 839f6cf4-02e4-4a52-971f-e1dbdca1d141) against shop.orders::Gateway: stand-in acme/gateway 0.1.0 (conformance level 3) at localhost:9092
```

An `ENVIRONMENT` section then lists each dependency and how many tested
obligations rely on it, or that none does. Proved laws, laws the compiler
checked itself, skipped laws and every other obligation are unchanged.

The attestation is reporting only: it never changes what a law means, whether
it passes or how it is discharged ref:DEC-environment-attestation. The
conformance level is the one the stand-in's maker declares; LawSpec records
it and does not judge it.

`lawspec evidence --attestation <file>` reads an attestation, as does an
`attestation` path in `lawspec.json`. `lawspec test --attestation <file>`
keeps the attestation with the run's results in `.lawspec/results`, and each
law it touches that passes in that run names it, so a later `lawspec evidence`
shows where each law last passed. See [the CLI](../cli.md#evidence).

## Reading the evidence

- `lawspec prove` submits selected supported law tasks to Z3 and retains its
  task-bound results. A solver model alone is not source-refutation evidence.
- `lawspec check` prints the number of obligations with each status.
- `lawspec evidence` lists each obligation with its claim and reason, grouped
  by status. It accepts a unit or a `unit::declaration` filter, and `--json`
  prints the API records. With an environment attestation it says where each
  tested law ran.
- The compiler API reports the obligations in the `evidence` field of every
  result, and a request's `attestation` adds where the tests ran. See [the API reference](../api.md#evidence).
