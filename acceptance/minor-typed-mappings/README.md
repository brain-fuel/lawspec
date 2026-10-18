# Checked delivery mappings

Seven mappings and seven laws exercise nominal record and payload constructor
keys, list fallbacks, equality-based sets, refined inputs and signed-zero output
classes. Ten expectation rows check the authored labels independently of the
derived helpers. Shared output labels retain both keys in source row order.

Run `lawspec-acceptance minor-typed-mappings [target...]`. Select compact 32-bit
projects with `LAWSPEC_MACHINE_BITS=32 LAWSPEC_MINIFY=1`. The suite selects
property tests, examples and runtime checks; its unbounded list law is sampled,
not proved. All definition contracts are mandatory regardless of these layers.

Two specification mutants change a nominal label or split a shared output
class. Each must fail the generated native tests. Native helper agreement does
not replace the independent label expectations or establish a universal proof.
