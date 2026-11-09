Manifest codec reference — Haskell application port

manifest-codec.json freezes 820 observations from revision a91b22f0 using
edn-data 1.2.2 and Node 26.8.1 on macOS ARM64. The receipt includes SHA-256
hashes of the original application template, generated implementation and the
dependency reader/writer. It records explicit input text, either an exact
error message or exact JSON, readable EDN and compact EDN output bytes.

The source reference is test-only:
  templates/npm/test/reference/manifest-codec.mjs
Its generated copy lives below npm/test/reference and is excluded by the npm
package's files list. It copies only the original codec, without compiler,
filesystem or application imports. Formatting follows the repository profile.
Do not replace this oracle with calls into the Haskell candidate.

Run from the repository root:
  stack test --fast --test-arguments '--match manifest EDN reference compatibility'
  node --test npm/test/manifest-codec-reference.test.mjs

The corpus includes all 47 tracked EDN files at the reference revision.
The initial cases cover ordinary project manifests, normalization, duplicate
keys, nested binding names, special object keys, JavaScript index-key order,
comments, discard forms, safe integer boundaries, integral decimal spellings,
Unicode and UTF-16 escapes (including lone surrogates), unsupported values,
incomplete inputs and malformed delimiters. The last 720 cases independently
delete or replace each character in three seed inputs; their results were
recorded from JavaScript before candidate acceptance, not derived from Haskell.
Node also verifies the optional file prefix and diagnostic location on errors.

The native candidate handles parsing and rendering of admitted manifest values.
The public writer's wider JavaScript input space (undefined, nonintegral or
nonfinite numbers, exotic objects, invalid options and non-map roots), complete
manifest validation/resolution, async helper behavior, component bindings and
resource limits still require separate fixtures and implementation. No public
entrypoint changes or subsystem completion follow from this corpus. Malformed
quirks are compatibility observations, not approval to expand the EDN grammar.

Replaying frozen observations is finite regression evidence. It is not a proof
of codec equivalence, definition validation or optional law verification.
