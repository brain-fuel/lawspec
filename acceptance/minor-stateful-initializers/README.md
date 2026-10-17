# Stateful initializers and equality precedence

Twelve laws and eighteen table rows check binding, conditional and case
initializers, state updates, explicit repeated calls, and equality mixed with
conjunction and worded negation. Sole, mixed and absent unit arguments cover
stateful and stateless handlers, pure functions and argument evaluation before
an operation. Each native target executes the generated tests. Three source
mutants must be rejected during exhaustive generation checking. Another two
must generate successfully and fail during native execution, identifying the
affected law. Scoped handler laws remain planned until that execution finishes.

Run `lawspec-acceptance minor-stateful-initializers [target...]`. Set
`LAWSPEC_MACHINE_BITS=32 LAWSPEC_MINIFY=1` for the compact 32-bit profile.
The technical language profile does not designate an RC release.
