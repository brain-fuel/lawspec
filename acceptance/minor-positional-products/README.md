# Positional products and parameter patterns

Seven laws and five independent table rows cover heterogeneous generic tuples,
nominal picture dimensions, nested records and alternatives, guard fall-through,
eleven-component position order, structural recursion and Eq-only set membership
with IEEE NaN behavior. Every target must execute the generated native tests.
Two specification mutants must be refuted during exhaustive generation checking;
these are separate from native implementation-conformance evidence.

Run `lawspec-acceptance minor-positional-products [target...]`. Use
`LAWSPEC_MACHINE_BITS=32 LAWSPEC_MINIFY=1` for the compact 32-bit profile.
The technical language profile does not designate this minor as a release candidate.
