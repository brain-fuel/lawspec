---
id: lawspec.review.s1j
kind: explanation
title: S1.j disposition
---
# S1.j disposition

This increment addresses the shared compiler, generation and tooling failures in
DEC-s1j-shared-failures and DEC-s1j-evaluation-budget. It preserves the host-SDK
work already present in this checkout. Original projects that were not supplied
remain awaiting confirmation; passing reduced regressions does not close them.
The teaching review and human/external release gates in
[the milestone contract](../../LAWSPEC-PRE-1.0-REVIEW.md) remain in force.

| Report | Change and regression family | Remaining confirmation |
| --- | --- | --- |
| 1 | Central Rapid range `>=1.2.0 <1.4.0`, scaffold 1.3.0; unsupported releases and local replacements rejected. Both released baselines execute the checked-strategy fixture. | Original dependency setup. |
| 2 | Intermediate `any` uses checked generation of its requested type, including nested binding, frequency and filtering; unrelated refinements do not require contracts for a plain Go schema. | Original constrained domain and shrink/replay artifact. |
| 3 | Imported collection operations retain their canonical prelude provider; import/re-export and shadowing regressions. | Original package graph. |
| 4 | Fresh-process cold/warm, damaged and disabled caches agree on macOS ARM64 under Node 22.23.4 and Node 24.21.0, including evaluation settings. Linux ARM64 also passes all five cache checks under Node 22.23.2 and 24.21.0. | Linux x64, macOS x64 and the unavailable WSL2 project; no crash fix is claimed without reproduction. |
| 5 | Empty substitution avoids repeated record expansion; flat construction measured through 64 fields. | Original wide record and workload. |
| 6 | Nested construction retains one strict proof prefix; admitted definition evaluation avoids repeatedly validating borrowed subvalues. Recursion is metered and measured separately. | Original recursive model; larger-model roadmap remains open. |
| 7 | Witness search explores every root constructor independently at increasing depth and uses canonical constructor order; constrained, impossible and recursive domain regressions retain exhaustion. | Original witness domain. |
| 8 | Configured Go factories and typed local bridges propagate into consuming packages; transitive provider/middle/consumer fixture uses a native record codec. | Original host integration. |
| 9 | Reserved syntax/type names documented from compiler lists; `Entry` is shadowable. | No new syntax aliases. |
| 10 | `prelude.all` supports the iterable domains of `any`, short-circuits, returns true on empty inputs and evaluates captures once. | Original use site. |
| 11 | `FileSystem.createDirectories` added to default handlers; nested parents and repeated creation covered by the resource fixture. | Custom handler migration and platform filesystem failures. |
| 12 | Public `mutate` command executes a passing baseline and independent temporary copies, reports actual failing laws, classifications, kill matrix and unique kills. | Project-specific mutants establish observed adequacy only. |
| 13 | Total-definition adapter-call errors explain abilities and effectful procedures. | Original call site. |
| 14 | Mutual recursion remains unsupported; checked parity restructuring example and an established-techniques roadmap added. | Separate future feature; not an implemented recursion checker. |
| 15 | Go package-local interfaces, transitive ability dependencies, sparse unit runtime materialization and handler wrapper migration documented and exercised. | Original workaround wrappers and package layout. |

## Measurement and trust boundaries

[Raw measurements](s1j-benchmarks.jsonl) come from `tools/bench-s1j.py` on macOS
26.4 ARM64 using the native compiler, with isolated processes. Wall/CPU time and
peak RSS include admission and process startup. Logical steps are the minimum
successful optional-evaluation allowance, found by binary search; admission is
never charged to that allowance. These are observations, not portable performance
guarantees. Parallel build load can affect elapsed times.

Flat widths and nested depths 4, 8, 16, 32 and 64 all admit successfully. Recursive
list depths 4 through 64, at 1, 8 and 32 inputs, all report exhaustive evaluation.
At depth 64 and 32 inputs this probe uses 166,304 logical steps. Construction of
literal recursive values still validates constructor boundaries and can exhibit
quadratic work; this is recorded for the larger-model roadmap rather than hidden
by raising a limit.

The proof-view optimization retains the complete strict construction prefix and
all constructor obligations; only its known constructor result is substituted
into an enclosing result. It follows the established practice of sharing local
proof computations instead of repeatedly expanding them. Why3's
[VC generation documentation](https://why3.org/doc/vcgen.html) describes the
related exponential-growth problem and sharing techniques. This local compiler
transformation does not constitute a Why3 backend.

Evaluation uses a deterministic per-law counter, following
[Lean's heartbeat precedent](https://lean-lang.org/doc/api/Lean/Util/Heartbeats.html)
with LawSpec-specific expression/value-node accounting. Public definition
arguments and external results remain validated. Only borrowed values inside
an admitted definition avoid redundant recursive validation; constructor
contracts and ordered pre/postconditions still run. The interpreter is trusted;
there is no proof-checking kernel or new solver integration in this change.

For future checked mutual recursion, the roadmap starts with
[Idris 2 totality](https://idris2.readthedocs.io/en/latest/tutorial/typesfuns.html),
[Rocq structural recursion](https://rocq-prover.org/doc/V9.0.0/refman/language/core/inductive.html),
Lean termination checking and SPARK/Why3 obligation generation. Generating an
obligation, executing a solver and checking a proof remain separate claims.

## Migration

- New Go projects use Rapid 1.3.0; existing stable 1.2.x projects remain accepted.
  Explicit LawSpec case counts override `RAPID_CHECKS`; explicit seeds override
  `RAPID_SEED`. Invalid Rapid environment values can fail during upstream startup.
- Every custom `FileSystem` implementation must implement `createDirectories`.
  `writeBytes` does not create missing parents.
- Go factories imported through `goImports` are forwarded in each consuming
  package with that package's codecs. Remove manually copied `New…Bound` wrappers
  when adopting generated bridges. Handler-only bridges use a generated file
  separate from user adapters; user adapters are preserved.
- `maxSteps` and `deferLaws` affect optional compiler evaluation, not definition
  admission or solver settings. Deferral/exhaustion is planned or incomplete,
  never completed evidence.
- Mutation copies are process isolation, not an operating-system sandbox. Native
  tools can have their ordinary external effects. Invalid edits or compiler
  rejections are not credited as killed laws.

During broad verification, two Groovy mutation/restoration checks observed Gradle
reporting changed source as up to date. LawSpec now passes `--no-watch-fs` to
Gradle test and benchmark invocations, refreshing input observations between
runs while retaining incremental compilation. This uses Gradle's
[documented filesystem-watching control](https://docs.gradle.org/current/userguide/file_system_watching.html);
it does not change LawSpec's passing-result cache or skip native checks.

## Verification ledger

Focused results: all 18 executable targets pass the checked-strategy and directory-resource fixtures in the default 64-bit profile and the 32-bit compact profile (72 suite/target/profile combinations; Scala uses an isolated Bloop daemon). The transitive Go handler and custom-codec fixture passes both profiles. Go additionally reports a regular-file parent conflict. Rapid 1.2.0 and 1.3.0 pass with explicit LawSpec case limits overriding upstream environment defaults. The public mutation integration covers a kill, a survivor, invalid edits, compile rejection, unexpected failures, timeout and workspace preservation. Its parser accepts all 2,798 existing acceptance mutants. The five cache checks pass on each of macOS ARM64/Node 22, macOS ARM64/Node 24, Linux ARM64/Node 22 and Linux ARM64/Node 24. Documentation validation compiles 137 snippets and resolves 130 pages. Native/WASM parity compares 625 complete responses, including 382 accepted generation responses.

The full native suite initially ran 2,836 examples and exposed two regressions: scoped undefined-candidate reporting (corrected during that run) and premature empty-list witness completion (subsequently corrected). Final rerun results follow below.

Project status and validation both pass definition admission, with verification explicitly unselected in the project manifest. Canon 0.2.3 status succeeds; its validation gate reports 47 pending owner sign-offs. No sign-off is manufactured. The default PATH Canon is older, so these commands explicitly select the matching built executable.
Platform rows without a recorded execution remain external gates. The existing
host-SDK platform gate is independent and must not be inferred to pass from these
compiler/tooling regressions.
