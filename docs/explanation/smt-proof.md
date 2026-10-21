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

The existing explanation views use the same typed law and updated obligation
evidence. Proving a law about checked definitions does not establish conformance
of a separate native implementation.

## Current translation boundary

The first encoding supports Boolean and integer quantifiers, machine-width and
unsigned bounds, exact arithmetic, conditionals, strict lets, short-circuit
logic, exact conversions, and nonrecursive calls to pure checked definitions.
It retains call preconditions and deferred runtime result checks. Rational
constants and rational-valued computations are supported; Rational quantification
is unsupported. SMT Reals include irrational witnesses, so substituting them for
Rational existential domains would change the proposition.

IEEE arithmetic, Decimal carriers, structural and nominal data quantifiers,
recursion requiring induction, effects, resources and native implementations
remain unsupported in this encoding. Other existing verification layers keep
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
