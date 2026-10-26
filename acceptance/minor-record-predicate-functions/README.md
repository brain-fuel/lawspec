# Checked predicates in record fields

Eight laws and eighteen independent table rows exercise nonrecursive pure checked
predicates inside anonymous records, generic structural GADT indices, ordinary
records and dependent sibling restrictions. A nested generic call retains
the Float64 argument chosen by its caller. The API checks the predicate laws over
complete finite domains. Native execution selects property tests and examples.
Two additional laws compare fields projected from a record within an alternative:
Rust must group the lowered match operand so the comparison remains one expression.

Run `lawspec-acceptance minor-record-predicate-functions [target...]`.
Use `LAWSPEC_MACHINE_BITS=32 LAWSPEC_MINIFY=1` for compact 32-bit projects.
A changed reciprocal must fail native tests. Changing the ignored argument's
type or strengthening its precondition must fail mandatory generation even
though both mutations leave the expanded predicate's body unchanged.
A reversed comparison must fail the independent passage-bound expectations.

Original calls use ordinary definition admission before expansion. Strict
argument evaluation and capture-avoiding substitution preserve the admitted
call. A dependency with deferred result checks is currently unsupported here:
expansion must not erase its runtime enforcement. Recursive and deeper predicate
expansion remain explicit limitations. Stored polymorphic GADT matches that
need local equality evidence are rejected until Core can retain that evidence. This is a minor-version demonstration,
not a release-candidate designation.
