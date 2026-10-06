# Evidence and discharge

Every obligation in a program reports how it is discharged. The statuses, from
strongest to weakest:

| Status | API value | Obligations | How |
| --- | --- | --- | --- |
| `PROVED` | `proved` | Laws over checked definitions; definition postconditions and indices | Statically, by the prover |
| `EXHAUSTIVELY CHECKED` | `exhaustively-checked` | Laws whose inputs form a finite domain | Every input, by the compiler or the generated tests |
| `PROPERTY TESTED` | `property-tested` | Other laws | Generated cases, boundary cases and examples |
| `RUNTIME CHECKED` | `runtime-checked` | Adapter contracts, definition preconditions, constructor constraints, native type bindings, non-linear definition indices | At every native boundary, or on each definition result |
| `DEFAULT HANDLER` | `default-handler` | The default handlers of built-in abilities (see [built-in abilities](builtins.md)) | Reviewed runtime code, its ability's laws property-tested, cryptography checked against NIST vectors |
| `ASSUMED / EXTERNAL` | `assumed` | Adapters, native functions, custom generators and codec hooks | Taken on trust |

The reasoning behind these categories is in
[evidence and discharge](../../explanation/evidence-and-discharge.md).

## Laws over checked definitions

A law that calls only checked definitions is attempted as a proof: its claim
must follow from its input refinements by the exact linear arithmetic that
proves definition results. Definitions without preconditions are unfolded into
the claim. A definition with preconditions stays a call, and its arguments must
be shown to satisfy them.

```lawspec
unit guide.evidence

definition twice (x :: Int32) :: BigInt is x + x end

law `twice doubles` is
  definition is
    `for all` (x :: Int32) . twice x = x * 2
  end
end
```

`twice doubles` is proved.

A law over checked definitions that is not proved, but has a finite domain of
at most `exhaustiveLimit` inputs, is evaluated by the compiler for every input.
A counterexample is a compile error with code `refuted`. This law, over `Int8`,
is rejected:

```lawspec fragment
definition twice (x :: Int8) :: BigInt is x + x end

law `always positive` is
  definition is
    `for all` (x :: Int8) . twice x > 0
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

## Reading the evidence

- `lawspec check` prints the number of obligations with each status.
- `lawspec evidence` lists each obligation with its claim and reason, grouped
  by status. It accepts a unit or a `unit::declaration` filter, and `--json`
  prints the API records.
- The compiler API reports the obligations in the `evidence` field of every
  result. See [the API reference](../api.md#evidence).
