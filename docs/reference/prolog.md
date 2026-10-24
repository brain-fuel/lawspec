---
id: lawspec.reference.prolog
kind: reference
title: Prolog target
---
# Prolog target

The `prolog` program target runs application predicates in SWI-Prolog through
Janus. Checked definitions, schemas and generated properties reuse the Python
target. PLUnit selects the actual pytest and Hypothesis cases, preserving their
shrinking, replay and JUnit observations. Public generation and execution are
implemented. The configured shared native acceptance matrix passes: default
64-bit readable suites and selected 32-bit compact/readable variants. Complete
selected-target CI and full native/WASM response parity also pass.

## Setup and commands

Use SWI-Prolog 10.x, Python 3.13 or newer and `janus-swi` 1.5.3.
Start the runner with the selected Python interpreter: a separately installed
SWI executable can embed a different Python. The scaffold declares the Janus
runtime dependency and the pytest and Hypothesis test dependencies.

```sh
lawspec init --target prolog
uv venv --python 3.13 .venv
uv pip install --python .venv/bin/python -e '.[test]'
lawspec generate
```

Set the target's `python` configuration field to the virtual environment's
interpreter. Run `lawspec doctor`, implement the generated user-owned `.pl`
adapters, then run `lawspec test`. Direct execution uses
`.venv/bin/python lawspec_test.py`. `lawspec examples --example payments
--target prolog` exports an application-owned implementation with exact-decimal
arithmetic and a Hypothesis generator factory.

The defaults are `src` and `tests`. `sourceDir` and `testDir` can be relative
nested directories without traversal. Generated checked-model predicates live
under `src/lawspec_models/`; application adapters live under the unit's ordinary
path. The launcher `lawspec_test.py` and selection manifest
`lawspec-prolog-tests.json` stay in the target root and carry the configured
module paths. Keep the generated module declaration when implementing an adapter.
A unit's module is named after the unit in snake case: `example.payments` is
module `example_payments`, and its checked models are `example_payments_model`.
A name an SWI-Prolog library module already has gets a trailing underscore.
Generated predicates use an `ls_` prefix to avoid protected SWI predicates such
as `close/2`. PLUnit test units are named after their host test file.

Generated Prolog is laid out as SWI-Prolog's `portray_clause/2` prints it, the
conventional layout of `listing/1`: atoms quoted only where `writeq/1` quotes
them, a module's exports one per line and a source link above each predicate.
The Python host files follow `ruff format`. Acceptance checks both: every clause
must equal `portray_clause/2`'s output (`tools/prolog-layout.pl`, which can also
rewrite a file with `--write`), and `ruff format --check` must pass.

## Predicate interface

A function takes its declared inputs followed by one output. Explicit ability
handlers precede the ordinary inputs. Every call must succeed deterministically
and return a ground acyclic term. Logical failure and remaining choicepoints
raise SWI determinism errors. The atom `false` is a valid Boolean result.

| LawSpec value | Prolog representation |
| --- | --- |
| Integers | Native arbitrary precision integer, checked against the declared range |
| Bool | `true` or `false` |
| Text and Char | SWI string |
| Float32 and Float64 | `ieee(Bits)` retaining the Python host's 64-bit float word; the schema enforces the declared domain |
| Complex | `complex(ieee(RealBits), ieee(ImaginaryBits))` |
| Decimal | `decimal(Sign, Digits, Exponent)` with the Python Decimal tuple conventions |
| Rational | `rational(Numerator, Denominator)` |
| Bytes | `bytes(ByteList)` |
| Raw text | `raw(Kind, Units)` |
| Unit, Null and Undefined | `absence(Kind)` |
| Algebraic data and records | `value(ConstructorIdentity, Fields)` in Core field order |
| List | Native list |
| Nullable and Optional | `presence(Kind, absent)` or `presence(Kind, present(Value))` |
| Symbol, handles and handlers | Opaque Janus references wrapped in `symbol/1`, `opaque/1` or `handler/1` |

Constructor identities are fully qualified Core identities, including the type.
The existing schema validates inputs and results, including refinements, indices
and machine widths. `lawspec_prolog:native_handle/2` exposes a handle's original
Python object for application API calls; returning the original opaque term
preserves its identity.

When calling Python APIs from an adapter, use Janus's `py_string_as(string)`
option for a returned LawSpec `Text`; Janus otherwise returns Python strings
as Prolog atoms. Use `py_object(true)` when retaining a Python collection as
an opaque native object. Python base strings, numbers, tuples and constants
still convert directly even with that option.

Raise a declared single failure with `throw(lawspec_failure(Payload))`. For an
explicit failure ability use `throw(lawspec_ability_failure(AbilityKey, Payload))`.
Undeclared abilities and invalid payloads are rejected. An incomplete computation
uses `throw(lawspec_incomplete("reason"))`; it remains incomplete in native
execution evidence, including when a model worker retains only an exception's
description. Unexpected exceptions remain execution failures.

## Native bindings and generators

A function binding such as `{"declaration":"payments::charge",
"native":["domain","payments","charge"]}` loads
`src/domain/payments.pl`, calls module `'domain.payments'`, predicate `charge`,
and emits no default stub for that function. Module names are data at the bridge
boundary. Quote dotted module atoms in Prolog source.

A handler binding names a constructor predicate whose result is an instance
token. A resource, when declared, precedes that result. Binding the constructor
`ledger` selects operation predicates such as `ledger_add(Token, Amount, Result)`.
Tokens must be ground and acyclic; Janus owns their foreign references.
Explicit handler arguments call operations through
`lawspec_prolog:operation(Handler, Name, Arguments, Result)`.

Native type bindings use their qualified reference as a Prolog identity. A
record constructor `['till','native','Cash']` with native field `cents` is
`'till.native.Cash'{cents:42}`. Variant constructors use qualified compound
functors with their arguments in the resolved native order; unit constructors
use qualified atoms. Explicit nested field layouts flatten and reconstruct
records using Core's resolved layout. Constructor and handle identities must
be distinct across the project. Results in the canonical `value(...)` form
cannot bypass a declared native representation. Both directions still pass
the checked Core schema, including field refinements and machine bounds.

A handle binding `['warehouse','native','Shelf']` uses a ground token with
functor `'warehouse.native.Shelf'`. Distinct live handles need distinct tokens.
Janus copies terms; keep mutable state in Prolog's database or retained foreign
objects rather than mutating token copies. A constructor binding calls predicate
`'Shelf'` in module `'warehouse.native'`, omitting `Unit` arguments. Method
bindings call that module's method predicate with the receiver first, followed
by the remaining arguments and the result. Constructors and method receivers
require a native handle type binding. Janus retains tokens; a weak identity
cache preserves repeated returns of the same token, compares hash collisions
by exact term identity and adds no strong references. Handle lifetime still
follows the existing Core handle registry and declared resource lifecycle.

Exception mappings match configured native atoms or compound functors, thrown
directly or as the formal part of `error(Formal, Context)`. A zero-argument
exception has an empty message; a one-argument exception supplies a Prolog
string. The checked mapping constructs its declared failure payload, including
nested single-field message products. Undeclared failures and unmapped errors
remain execution failures. Native handlers and explicit capability proxies
use these same representation conversions.

Generator bindings use the existing `generators` configuration entries. Their
factories live below `testDir`, receive one Hypothesis child strategy per type
parameter, and return a Hypothesis strategy as a Janus Python object. For example:

```prolog
:- module(prices, [small/1]).
:- use_module(library(janus)).

small(Strategy) :-
    py_call('hypothesis.strategies':integers(100, 200), Strategy,
            [py_object(true)]).
```

Bind this factory to an appropriate integer type with `factory:["prices","small"]`.
Data generators return the generated Python data classes from `lawspec_data`;
the exported payments example demonstrates this. Hypothesis retains its own
shrinker, and the existing native-generator schema checks every sample and
shrink. Invalid values fail instead of becoming discarded samples. The `stub`
option scaffolds a user-owned Prolog factory that must be implemented.

## Models and execution scope

`lawspec_prolog:model(Identity, Arguments, Result)` calls a checked definition by
Core identity. To retain symbol identity across calls, create a context with
`new_context(Context)` and call `model(Context, Identity, Arguments, Result)`.
Checked-model calls retain explicit ability identities and typed failures.

Async adapters reuse the host Async task runner, propagate context variables,
and await a shielded future with Janus thread attachment. Cancelling the
waiting task does not forcibly terminate the running Prolog predicate or make
event-loop shutdown wait for that predicate. Losing native work can finish
after a timeout or hedge has returned.
Respect Janus's documented GIL and mutex ordering in application callbacks.
The selected host cases run in one pytest session. The existing host harness
controls seeded ordering, parallel workers and unit resource scopes; PLUnit
reads the actual per-slot outcomes without executing those cases again.
Generated assertions retain their explicit law, argument and expected-value
messages. The runner uses plain assertions and standard Python tracebacks to
avoid repeated AST processing of large generated modules. Optimized Python
execution (`-O` or `PYTHONOPTIMIZE`) is rejected before tests run, so disabled
assertions cannot become successful evidence.
Context-local execution identities preserve incomplete results from parallel
workers. An event from an unscoped child thread conservatively invalidates
the currently active cases; an event with no identifiable active case
invalidates the selected batch.

Coverage instrumentation and custom native codec hooks are unsupported and
produce explicit errors.

The execution trust boundary includes SWI-Prolog, Janus, Python, the property
frameworks and application predicates. This target adds no obligation generator,
solver executor or proof checker. A successful native run establishes the
recorded conformance scope. Provider fidelity requires independent conformance
checks; generated-model agreement alone does not establish it. Mandatory
definition validation remains independent of optional law verification.

See [Janus calls](https://www.swi-prolog.org/pldoc/man?section=janus),
[Janus threading](https://www.swi-prolog.org/pldoc/man?section=janus-threads),
and [Hypothesis custom strategies](https://hypothesis.readthedocs.io/en/latest/tutorial/custom-strategies.html).
The precedent and trust-boundary mapping are recorded in `DEC-prolog-janus`.
