# Payloads determined by constructor indices

Four laws and ten independent table rows exercise fixed UInt8 and Boolean
indices, a structural record index, and related List/Boolean indices. Generic
functions match each constructor using its own equations. Every supported
target runs the generated native tests.

Two specification mutants supply a payload or result that disagrees with the
constructor equation. Mandatory definition admission must reject them during
generation, including with no selected law layers. These are specification
rejections, not native implementation mutants.

Run `lawspec-acceptance minor-gadt-payload-indices [target...]`. Use
`LAWSPEC_MACHINE_BITS=32 LAWSPEC_MINIFY=1` for the compact 32-bit profile.
The technical language profile does not designate a release candidate.
