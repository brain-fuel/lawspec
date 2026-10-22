---
id: lawspec.explanation.smt-proof
kind: explanation
title: Proof with Z3
---
# Proof with Z3

LawSpec can send selected law obligations to an installed Z3 executable. The
compiler produces a typed SMT-LIB task. A separate Node host executes Z3 and
records the result. Mandatory definition checks still run before tasks are
available, including when no law verification layers are selected.

Select `proof` in configuration version 2's `verification.layers`, then run:

```sh
lawspec prove --solver /path/to/z3 --json
```

`--solver` defaults to `z3` on `PATH`. `--proof-timeout` sets milliseconds;
`--proof-memory` sets the solver's memory limit in megabytes. `--proof-rlimit`
sets Z3's resource counter limit, and `--proof-seed` records its random seed.
No proof layer selected means no solver invocation. The command reports that
explicitly. Exit status 2 means a selected task remains incomplete or unsupported;
compilation and configuration errors use exit status 1.

The package exposes the same host through `lawspec/proof`:

```js
import {createCompiler} from 'lawspec';
import {proveWithZ3} from 'lawspec/proof';

const compiler = await createCompiler();
const result = await proveWithZ3(compiler, {
  languageProfile: '1.0-rc.2',
  verification: {layers: ['proof']},
  sources,
}, {binary: '/path/to/z3', timeoutMs: 5000});
```

`compiler.proofTasks(request)` only prepares tasks. It does not execute Z3 or
produce solver evidence. `lawspec prove` invokes Z3; ordinary compiler checks
remain independent of an external solver installation. The default browser API
stays independent of Node's
process facilities. The Node host can execute tasks produced by the WASM or
native compiler using the same protocol.

## Reading evidence

A successful `unsat` answer establishes the submitted law obligation according
to the typed translation and selected solver. It is not a Lean or Rocq
kernel-checked proof certificate. The evidence records the exact task and checked
program hashes, machine profile, Z3 executable hash and version, configuration,
execution hash, elapsed time, exit status and raw output.

A `sat` answer is not a counterexample by itself. The host then runs the
task's counterexample query. It declares the law's outer inputs as constants,
and Z3 gives their values with `get-value`. The compiler reads the values back
and checks the law at them with the reference evaluator, the one behind
`exhaustively-checked`:

- `refuted`: the evaluator finds the law false, or undefined, there;
- `model-not-confirmed`: the law holds there, or a value is outside the law's
  domain. The translation or the solver is wrong, and the host reports a
  `proof-translation` diagnostic;
- `incomplete`: the rest of the law has quantifiers that cannot be searched
  completely, or Z3 gave a value that cannot be read back.

Quantifiers inside the law are searched completely when their domains are
finite and within `exhaustiveLimit`. Z3 is only a search tool here: a
refutation trusts the evaluator, not Z3. This follows
Why3's `--check-ce`, which
runs the model through runtime assertion checking. Undefined computation can
also prevent a positive proof. Unknown answers, timeouts, resource limits,
unavailable executables and protocol failures remain explicit incomplete results.
An imported JSON report cannot upgrade a source law through this host.

## Law sets

The [law-set checks](../reference/language/law-sets.md) use the same rule. A
task for completeness, overlap or conflict asks Z3 for an input. The compiler
reads the input back and runs the laws there with the evaluator. Only a
confirmed input is reported. An `unsat` answer proves the check, trusting the
translation and Z3. For vacuity, Z3's input is a witness that a law's
assumptions can hold, and the evaluator confirms it too.

The existing explanation views use the same typed law and updated obligation
evidence. Proving a law about checked definitions does not establish conformance
of a separate native implementation.

## Current translation boundary

The first encoding supports Boolean and integer quantifiers, machine-width and
unsigned bounds, exact arithmetic, conditionals, strict lets, short-circuit
logic, exact conversions, and nonrecursive calls to pure checked definitions.
It retains call preconditions and deferred runtime result checks.

Effects, resources and native implementations remain unsupported.

### Numbers

Tasks that quantify `Rational` or `Decimal` inputs, or use `Decimal` or
IEEE floats at all, are `lawspec-smtlib-v2`.

- A `Rational` input is an integer over a positive integer. SMT Reals include
  irrational numbers, so a Real witness could change the proposition; this
  one cannot. `there exists (x :: Rational) such that 3 * x = 1` is proved,
  and `x * x = 2` is not.
- A `Decimal` is exact, as a Real. A law for all decimals is proved for all
  Reals, which include them. A witness is a multiple of 10^-18, so it is a
  decimal. A `Rational` becomes a `Decimal` only when its denominator divides a
  power of ten; that conversion is unsupported.
- `Float32` and `Float64` are SMT-LIB's IEEE binary32 and binary64, rounding
  to nearest, ties to even, as LawSpec's arithmetic does. Equality is IEEE's:
  NaN is not itself, and the two zeros are equal. `prelude.isNaN`,
  `isInfinite`, `isFinite` and `isNegativeZero` map to Z3's tests. Data with
  a float field is refused, because SMT equality on data is structural.

Z3's values are read back exactly: a rational or decimal, or a float's bits,
for the evaluator to check. A law true for real numbers but not for floats,
such as `x + 1.0 > x`, is refuted with a float the evaluator confirms. Recursive definitions are unfolded (see
below); laws that need induction stay incomplete.

### Data

Tasks over data are `lawspec-smtlib-v2`. Enums, records, alternatives,
structural records, `Maybe`, `List` and `Either` become SMT datatypes, one for
each instance used, such as `Maybe<Int32>`. Constructors, selectors and
testers keep their LawSpec names, as quoted symbols like
`|Maybe<Int32>#Just|`.

- A datum must be well formed: each integer field in its type's range, each
  nested datum well formed, and each field refinement true. Quantifiers range
  over well-formed data only, and building a datum that breaks a refinement is
  undefined.
- A match reads a field only under the tester of the constructor that has it.
  A field read from another constructor is undefined, never Z3's arbitrary
  value.
- Equality on data is structural, as LawSpec's is.
- `List` laws over recursive definitions, such as length or membership, are
  unfolded as below.
- Handles, indexed families, constructors with existential or refined type
  parameters, `Rational` fields and types with no finite value are refused.
  An SMT datatype must have a value, and LawSpec allows empty types. Other existing verification layers keep
their own capabilities. Unsupported translation never substitutes an
uninterpreted implementation or changes a law's domain.

The architecture follows [Why3's verification-condition separation](https://why3.org/doc/vcgen.html)
and its [prover-call interface](https://github.com/AdaCore/why3/blob/e8a19d2c821959079c8e24510bc607dd25a276fd/src/driver/call_provers.mli).
LawSpec retains its own semantics at that boundary. For example,
[Z3's arithmetic theory](https://microsoft.github.io/z3guide/docs/theories/Arithmetic/)
allows underspecified division by zero; LawSpec's exact division requires a
nonzero denominator. The task must establish definedness as well as truth.
Likewise, proving nonexistence requires ruling out every admitted candidate;
an undefined candidate cannot simply count as false.

### Text

Tasks over `Text` are `lawspec-smtlib-v2`. A `Text` is an SMT string of
Unicode scalar values: a task assumes no surrogate code points. `++`,
`prelude.length`, `prelude.slice` (clamped as LawSpec clamps it),
`prelude.textOf` of an integer, `prelude.compare`, `starts with`,
`ends with`, `contains` and `matches regex` with a literal pattern map to
Z3's string theory. Every portable regex (see
[matchers](../reference/language/matchers.md)) maps to an SMT regular
expression with the same whole-text meaning. A test checks the translation
against LawSpec's own matcher on each regex's sample texts. Z3 reads a
counterexample's text back as LawSpec does.

Z3 models code points up to U+2FFFF only, and LawSpec's text goes up to
U+10FFFF. A task with a literal character or a regex range end above U+2FFFF
is unsupported. No operation exposes a character's code point, so any other
task cannot tell the missing characters apart from ones Z3 has, and a proof
holds for all text. Z3's string theory is undecidable in general; expect
`unknown` for some laws that mix lengths and contents.

`prelude.length` and `++` over a `List` are functions defined by structural
recursion over the list (`define-fun-rec`).

### Recursive definitions

A law that calls a recursive checked definition gets a `lawspec-smtlib-v2`
task. Only definitions that pass the mandatory totality check reach Z3, so a
definition that does not terminate is refused before any task exists. The
task gives Z3 the definition in one of two ways:

- **Unfolding step by step** (`guarded-axioms` in the task). The definition
  is a declared function with a defining axiom, as Why3's
  `eliminate_recursion` does. The axiom holds only on the definition's
  domain: its argument types and preconditions. As in Dafny, each call
  carries fuel. A call in the law starts at fuel 2, each unfolding uses one,
  and at zero the call is left unknown. The task records its fuel.
- **Solver recursion** (`define-fun-rec` in the task). The same guarded body,
  unfolded by Z3 itself.

By default each task carries both, and `lawspec prove` tries unfolding step
by step first, then solver recursion. A law's harness can choose one, or set
the fuel (see [proof settings](../reference/language/harness.md#proof-settings)).
The evidence names, in plain words, the encoding that proved the law, with
each attempt and its outcome; the task JSON keeps the SMT names. Unfolding
step by step proves laws that need a few unfoldings over any input, such as
`count (Cons x xs) = 1 + count xs`. Solver recursion proves laws over fixed
inputs of any depth, such as `count [1, 2, 3] = 3`. Laws such as
`count (append xs ys) = count xs + count ys` need induction (below).

A law that is not proved over recursive definitions also gets a
counterexample search: Z3 unfolds the definitions freely there, and the
evaluator checks any input it gives. So `count xs > 0` is refuted at
`xs = []`. A law with no inputs, such as `count [1, 2] = 3`, is decided by the
evaluator directly.

Calls with fuel left are linked to the function, which is the same at every
fuel; a hypothesis or cited law names that function, and where one does, the
function unfolds once more. Two facts come from mandatory admission, not
from Z3. On its domain, a
recursive definition is defined, and its result lies in its result type.
Admission proved both by induction over the calls it proved terminate. A call
is defined when its arguments are in the domain and its runtime
postconditions hold. So `count xs >= 0` is proved without induction. These
tasks set `smt.mbqi` and `auto_config` to false, as Dafny does, so unfolding
follows the axioms' patterns and stops at the fuel. A model from such a task
may rest on an unfolding that stopped early. The evaluator checks it as
usual. If the evaluator does not confirm it, the law stays incomplete, and no
`proof-translation` error is reported.

### Induction

`prove by induction on xs` proves a law by induction on its input `xs`, as
Why3's `induction_ty_lex` and `induction_int_lex` do:

- for a data type, one case for each constructor, with the law assumed for
  each field of the same type (`tail` in `Cons head tail`);
- for a whole number or a bounded integer, the lower bound, and then `n` with
  the law assumed at `n - 1`.

In each case the law is assumed for the smaller value at the case's other
inputs, and for all of them. Each case is its own task with its own receipt,
tried in the law's encodings in turn. The law is `proved` only when every case
is. A case Z3 cannot decide leaves the law `incomplete`, and the reason names
the case.

`using "|a|` assumes the cited law in every case. The citing law's evidence
rests on the cited law's: while a cited law is not proved (or checked on every
input), the citing law is `incomplete`, and the reason says which law it waits
for. Cited laws must be laws of the same unit, and cycles are refused.

When Z3 finds a model of a case, the evaluator checks the law at the model's
input. If the law fails there, it is `refuted`. If it holds, the model fails
only the case: the induction hypothesis is too weak, as Why3 reports it. The
law stays `incomplete` and the reason says so.

Assumed laws (hypotheses and cited laws) name their triggers: the calls to
recursive definitions they make, the outermost first, so Z3 uses them as
rewrites from left to right and never matches a well-formedness test, which
every datum would match.

## Encodings and receipts

Every task names its encoding. `lawspec-smtlib-v1` is frozen: a task it
supports keeps its script and fingerprint byte for byte. A receipt recorded
for such a task stays current, so nothing needs to run again. A test checks
this against a frozen corpus of tasks in `test/fixtures/smt-v1`.

A task that needs a feature v1 lacks, such as data types or text, is
`lawspec-smtlib-v2`. The counterexample query beside a v1 task is v2 too; the
v1 task itself is unchanged. A task v1 refuses never becomes a v1 task. The task
fingerprint covers the encoding name, so a v1 receipt never stands for a v2
task.

The mandatory definition audit reduces variable aliases by capture-avoiding
substitution, following [Lean's zeta reduction of local definitions](https://lean-lang.org/doc/reference/latest/The--grind--tactic/Local-Definitions/).
Both source and Core lowering share that reduction. Other strict bindings retain
their evaluated prefix so an unused partial computation still fails validation.
