# Ordered execution and source branch typing

Four laws and four independent table rows exercise discarded Boolean guards,
constructor-local GADT equations, generic record fields without Eq, exact
UInt8 results, and the order of first-matching cases. Every supported target
executes the generated native tests.

Two specification mutants introduce an invalid result or guard in a discarded
row. Mandatory definition admission must reject them during generation,
including when optional law verification is disabled. They are not native
implementation mutants.

Run `lawspec-acceptance minor-branch-admission [target...]`. Use
`LAWSPEC_MACHINE_BITS=32 LAWSPEC_MINIFY=1` for the compact 32-bit profile.
The technical language profile does not designate a release candidate.
