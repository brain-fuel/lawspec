---
id: lawspec.explanation.business-examples
kind: explanation
title: Reviewing business policies
---
# Reviewing business policies

The complete [refund policy](../../examples/rc1/refund-policy.lawspec),
[native conformance specification](../../examples/rc1/refund-conformance.lawspec),
[conflicting requirements](../../examples/rc1/conflicting-requirements.lawspec)
and [order workflow](../../examples/rc1/order-workflow.lawspec) show different
questions a requirements review needs to answer. They use the current minor's
canonical authoring profile. These sources pass intrinsic definition checks
with no law layers selected; that does not verify their requirements.

## Refund decisions

The refund policy evaluates its cases in order:

| Request | Decision |
| --- | --- |
| Zero amount | Approved |
| More than was captured | Rejected |
| Positive eligible amount, flagged | Review required |
| Remaining eligible requests | Approved |

A zero refund therefore needs no review, including when flagged. An excessive
refund is rejected before the review condition is considered. Four laws express
these obligations; ten independently supplied table outcomes exercise the
boundaries and priority. One amount exceeds binary floating-point's exact
integer range. `Whole` retains its exact value.

Select property and example execution to check the generated native policy.
The population of all `Whole` amounts is unbounded. Selecting exhaustive checks
alone reports that limit rather than claiming every refund was checked.
Native tests establish conformance for their actual cases; table outcomes do
not become a proof for the unbounded population.

The conformance specification imports the checked policy and compares it with
the application's `nativeRefund` adapter. It repeats the ten published outcomes
independently of the reference function. The acceptance suite supplies a hand
implementation in each of the 17 languages and a native decision mutation for
each. Changing the reference or the native implementation must expose a
disagreement. A production application supplies and tests its own adapter.

## Contradictory requirements

The conflict example requires every request to be approved and also requires a
flagged request to receive review. For the same `true` input, `Approved` and
`ReviewRequired` are distinct results. Moving either law earlier cannot resolve
that contradiction.

The proposed function sends flagged requests to review. Selecting exhaustive
law checking refutes “every request is approved” at `flagged = true`. Changing
the function to approve every request instead refutes “a flagged request
requires review.” The source remains a valid, total computation in both cases.
The stable diagnostic code is `refuted`.

These are concrete refutations of proposed implementations. The example does
not claim that a solver has performed general joint conflict or completeness
analysis. Documentary order and references cannot discharge either obligation.
The business owner must revise the requirements, such as explicitly limiting
automatic approval to unflagged requests.

## Stateful orders

An order starts pending. Authorization permits dispatch. Cancellation is final,
and a shipped order remains shipped. Twelve table rows cover every single-step
state/action combination; eight complete histories check sequencing and the
terminal states.

`OrderStore` makes state an explicit ability. Its `inMemory` handler owns one
order's state. The procedures read, transition and save that state; `runOrder`
gives each invocation a fresh handler. The separate history model checks that
each action sees its predecessor's completed transition. An additional law runs
two independent orders to expose state leaking between invocations.

These histories are finite, sequential executions with a fresh in-memory
state. They make no concurrency, durability, scheduling fairness or complete
history-search claim. A production store or concurrent actor needs separate
implementation and model evidence.

The `business-refunds-orders` acceptance suite runs the positive examples and
nine deliberate reference, state and native-decision mutations through each
native target. Its tests
keep the independent table outcomes; changing both a policy and its expected
answers would not be an independent conformance check.
