# Java backend (0.9)

Java targets Java 25+, JUnit, and JetCheck. The compiler emits native named
products and sums, checked scalar/data codecs, reusable runtime sources, and
separate property-test helpers. Native type parameters remain visible in public
data declarations and adapter signatures.

## Total definitions

A unit-level definition supplies its implementation together with its signature:

```lawspec
unit example.total

definition size (xs :: List Int8) :: BigInt is
  match xs with
    | Nil -> 0
    | Cons head tail -> 1 + size tail
  end
end
```

The compiler checks the body even when no law uses it. It requires exhaustive
matching, established structural descent for recursion, and proof that partial
operations are defined. Calls may target other checked definitions, including
forward declarations; definitions cannot call external adapters. Generic definitions specialize to concrete uses. Refined signatures become
checked contracts, and refinement predicates may call checked definitions.

Java writes native entry points beneath `lawspec.definitions`, preserving the
unit's package and class mapping. The example above provides
`lawspec.definitions.example.Total.size`:

```java
var symbols = new java.util.HashMap<String, Object>();
var count = lawspec.definitions.example.Total.size(symbols, java.util.List.of((byte) 1, (byte) 2));
```

Arguments and results use the same checked native representations as generated
data codecs: `List<Byte>` and `BigInteger` in this example. Domains without a
faithful Java representation retain their tagged runtime support values,
including nested Nullable/Optional states and machine-profile integers. Share
the Symbol map when fixture IDs should refer to the same identity.

`LawSpecDefinitionBodies.java` contains generated checked implementation helpers.
Generated properties call those same bodies. The native entry points validate
and copy values through codecs, and invalid native values report the definition
identity in an `IllegalArgumentException`. Logical machine integers enforce the
selected 32- or 64-bit range independently of the JVM architecture.

These files belong to source directories and have no JUnit or JetCheck dependency.
Definitions never receive user-owned adapter stubs. External declarations still
receive stubs, and regeneration preserves edited adapters. Edits to generated
definition files are protected by the generation manifest.

## Verification and layout

`tools/java-definitions-integration.mjs` executes recursive list/tree definitions,
forward calls, scalars, sums, raw code units, Symbol identity, and nested absence
under both profiles. It checks custom source/test roots, typed native misuse,
incorrect adapters, framework-independent compilation, and ownership.

Readable generated sources and tests use structured formatting that matches
Google Java Format. `tools/java-formatting-integration.mjs` checks all bundled
examples and the total-definition fixture under both machine profiles. The
compiler emits this layout directly; generation does not invoke a formatter.
JetCheck combinators retain native shrinking and the existing scalar domains.

The CLI/API accept explicit minify. Native integration checks run
both readable and fully minified generation plans, including properties and
contracts. Independent Java execution checks preserve long diagnostics,
supplementary Unicode, escaping and arbitrary integers when literals wrap.
The bundled WASM package is checked against the native compiler.


For internal checked Core definitions, shared JVM implementation bodies now
prove attached contracts before emission and enforce ordered preconditions and
validated-result postconditions at runtime. Native wrappers and direct logical
entry points both use those checks. `tools/jvm-definition-contract-integration.mjs`
verifies both JVM languages, profiles and layouts without a test-framework
dependency, including corrupted-result rejection. Refined source signatures
now produce these contracts through template proof and specialization.


## Constructor contracts

Public Java generation supports typed constructor callbacks, context-aware codecs
and definition boundaries. Property emission supplies validated witnesses and one
Symbol context shared by generation, adapter conversions and assertions.
Required conjunctive Symbol equalities can use fixture/prior-input values;
equalities beneath disjunctions contribute candidates without restricting the
whole domain to one alternative.

The test helper's `checkedGenerator` composes JetCheck generators with native
`suchThat` filtering at nested and outer value boundaries. False predicates reject
candidates; predicate evaluation errors are retained for the property to report.
Each filter respects the smaller of `maxAttempts` and JetCheck 0.3's native
100-attempt limit. The counter for smaller budgets is recreated on replay, so
native filtering still discards invalid shrinks. Validated witnesses contribute typed nested seeds. Sampled seeds
can limit payload shrinking; native list and constructor generation remains an
alternative, and shrinking does not promise a globally minimal counterexample.

`tools/java-checked-strategies.mjs` verifies valid generation/shrinking, nested
witness use, exhaustion, error classification and shared Symbol identity at both
machine widths, with compiled behavioral mutants. These helpers depend on
JetCheck; the value/schema/codec runtime remains framework-independent.

Constructor-contract properties run the requested case count as one-iteration
JetCheck sessions with increasing size hints. This preserves native shrinking and
avoids session-wide draw-uniqueness exhaustion for fixture-identity domains. It
does not claim those domains are finite; domains proven finite by Core retain
exhaustive cases. `tools/java-field-properties.mjs` executes public generation at
both widths and layouts, including custom placement, adapter mutants, disjunctive
Symbol candidates and generation-time evaluator errors.
