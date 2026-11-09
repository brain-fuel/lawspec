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
manifest service/resolution cutover, async helper behavior, component bindings and
resource limits still require separate fixtures and implementation. No public
entrypoint changes or subsystem completion follow from this corpus. Malformed
quirks are compatibility observations, not approval to expand the EDN grammar.

Replaying frozen observations is finite regression evidence. It is not a proof
of codec equivalence, definition validation or optional law verification.

Manifest service reference

manifest-service.json freezes 739 componentRequest inputs and outputs from
cd60ba5c, before extracting manifest admission and version selection. Its
receipt fingerprints Component.hs, Packages.hs and Targets.hs. The reference
was a native GHC 9.10.3 executable linked against that revision's library:
read JSON lines, decode each as Value, apply componentRequest, encode the
Maybe Value response (Nothing is null). Capture happens before rebuilding the
candidate; never regenerate expected responses from the candidate service.

The inputs cover every admitted top-level field, missing versus null, wrong
shapes, unknown-key ordering, identities, target entries, source dependencies,
nested source-version declarations, exception whitespace, contract fields,
version precedence/ranges, duplicates and malformed candidates, schema versions
and unrecognized methods. Combined field mutations use seed 320. Another 248
inputs use accepted outputs from manifest-codec.json, including the tracked EDN
manifests. One lone-surrogate output is excluded from this Value-level corpus
because Aeson rejects its JSON encoding; it remains covered at the EDN codec
boundary. This fixture does not claim raw malformed-JSON transport coverage.

647 inputs also carry their EDN spelling. Tests admit these directly through
Haskell and compare ordered diagnostic messages with the independent reference.
The other JSON inputs include non-map roots, fractional numbers, missing fields
and version requests that are outside the restricted EDN document surface.
The service suite adds one check distinguishing EDN syntax errors from admission
errors: 1,387 checks total. Run the compiled test executable with:
  --match 'manifest service reference compatibility'

Version admission is intentionally unchanged. Relative to SemVer 2.0.0
(https://semver.org/), the current parser rejects build metadata but permits
numeric leading zeroes and Unicode alphanumerics in prerelease identifiers.
These are compatibility observations, not new language requirements.

The native JSON adapter and direct EDN path share domain records and admission
rules. The boundary check rejects compiler dependencies in these services.
Typed WIT exposure, component/resource limits, resolution, identities, public
async helpers and the separate controller artifact remain outstanding.
