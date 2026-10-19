# Chapter 6 assembler conformance

[assembler.lawspec](assembler.lawspec) is the formatted canonical specification.
Its authoring pass uses six checked mappings for computation, destination and
jump encodings, readable assembly-source and reference-assembly function names,
and descriptions for all 23 laws. `AssemblyRuns` names the first, second and
repeated first output separately so repeated calls remain observable. The root
[chap06.lawspec](../../chap06.lawspec) contains the same canonical source; the
oracle harness requires both entry points to agree.

The `assemble` adapter takes assembly text and returns physical `.hack` lines
as `List Text`, with `[]` for an empty output file. A command-line adapter runs
`Program.asm` and reads its sibling `Program.hack`. Split LF/CRLF and remove
only the final split artifact of a trailing newline. Preserve all other output:
trimming, decoding, padding or filtering would conceal implementation defects.
The checked structured reference has no assembly-text parser and never calls
the native assembler under test.

[python/hack_assembler.py](python/hack_assembler.py) implements the valid-program
contract for the [Nand to Tetris assembler project](https://www.nand2tetris.org/project06).
It returns physical binary lines from `assemble(source)` and supports the course's
file interface:

```sh
python3 examples/chap06/python/hack_assembler.py Program.asm
```

The command writes the sibling `Program.hack`. Every call creates a new symbol
table and allocates variables from RAM address 16. Invalid-program diagnostics
are outside the Chapter 6 specification's contract.

From the repository root, run the native checks with Python 3.13+, pytest and
Hypothesis installed:

```sh
node tools/chapter6-oracles.mjs --property
LAWSPEC_MACHINE_BITS=32 LAWSPEC_MINIFY=1 node tools/chapter6-oracles.mjs --property
```

Set `LAWSPEC_PYTHON_EXECUTABLE` when the interpreter is outside
`.integration/python/.venv/bin/python`. The default compiler is the repository's
actual WASM package; `LAWSPEC_CORE` selects a native compiler executable.
Each invocation preserves a fresh project, logs and `evidence.json` under
`.artifacts/chapter6-oracles/`.

The harness checks the canonical source through the ordinary compiler.
It retains 23 laws, 65 expectation-table rows, one named example,
25 authored definitions, seven ADTs and two refinements. Six of the authored
definitions are mappings; compiler-derived inverse/preimage and field helpers
are additional lowered definitions. Mapping rows are counted separately from
expectation-table rows. It runs the 66 generated examples against the Python
assembler. Independent checks cover all 32,768 A-instruction
addresses and all 1,792 canonical C-instructions, against both the assembler and
the emitted checked codec functions. Thirteen further programs check symbols,
labels, comments, whitespace and independent repeated calls. File-interface
checks compare exact output bytes, including empty output.

Five native mutants must fail these independent checks: losing an address bit,
losing the memory computation bit, exchanging destination bits, shortening
physical output lines, and leaking a symbol table between calls.
A sixth mutant changes the checked specification's computation table while
keeping the native assembler correct. It passes intrinsic definition checks
with no selected law verification, then fails the independent C-instruction
oracle. This checks the specification against the external vectors as well.

The C-instruction fixture comes from the course's independently maintained
[decoder](https://github.com/nand2tetris/web-ide), pinned by revision and source
digests in [provenance.json](../../test/fixtures/chapter6/provenance.json).
It is not generated from LawSpec's `compBits`, `destBits`, `jumpBits` or
`computeWord`. Regenerate and compare it using TypeScript's `tsc` and an
internet connection:

```sh
node tools/chapter6-reference.mjs --check
```

`LAWSPEC_TSC` can select the TypeScript compiler. Normal oracle checks use the
versioned vectors offline. The reference command fetches only the pinned
upstream source and checks its exact digests before compiling the decoder.

These checks establish finite codec coverage and Python conformance for the
executed programs. These finite tests do not prove the unbounded program laws or
establish implementations in the other 16 languages.
`--property` additionally selects property testing and generated boundary cases
for all 23 laws. The evidence counts actual properties, boundaries, examples
and replay hooks separately; a replay hook alone does not establish that a law
was exercised. Omitting this flag runs the 66 examples and independent oracles.
`LAWSPEC_SEED` selects their repeatable seed, defaulting to 6061 and recorded
with the compiler's generation settings in the evidence.
The remaining pre-final-1.0 gates remain in the
[review packet](../../LAWSPEC-PRE-1.0-REVIEW.md).
