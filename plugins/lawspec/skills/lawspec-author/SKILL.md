---
name: lawspec-author
description: Write or change LawSpec specifications and native adapters using the installed prelude, generated models and explicit bindings. Use for ordinary authoring; use lawspec-project for project discovery and lawspec-learn for tutoring.
---

# LawSpec authoring

Inspect what LawSpec provides before creating another implementation or representation.
Print the references with the installed compiler. Read the authoring guide,
`lawspec reference authoring.md`, for the workflow and worked cases. Search the
compiler inventory, `lawspec reference library.json`, for facilities. Read the
library reference, `lawspec reference library.md`, for their semantics, and the
reusable law source, `lawspec reference prelude.lawspec`, for argument order.
They come from the compiler the project runs, so no repository checkout or
other skill is required, and they never describe a different version.

1. Run `lawspec --version`, and use these references or the installed
   package's documentation for that version.
2. Search prelude operations and law templates before writing helpers. Compare
   domains, equality, ordering, duplicate counts, absence and failure semantics.
3. Use `lawspec check` and `lawspec generate --target <target>` in the project,
   then read the actual generated declarations, constructors, checked definitions
   and user-owned adapter stubs before writing native code. For read-only
   discovery, use the SDK's `planGeneration` and inspect its returned files.
4. Prefer the generated model and runtime. Migrate corresponding application
   types within the authorized scope. Retaining application types is an explicit
   choice: configure checked native bindings or supported codecs, with a reason.
   Never guess representations or maintain an accidental parallel model.
5. Run `lawspec check`, then `lawspec test --target <target>` and relevant native
   application tests. New projects select no law layers; configure the intended
   example/property layers as shown in the guide and inspect executed counts.
   Preserve deliberate existing verification selections. Report definition validation separately from selected law
   evidence; unsupported, incomplete and not-verified are not passes.

Custom work is appropriate for domain-specific meaning, materially different
semantics, missing facilities, independent reference models, and explicitly
identified teaching examples. Explain which applies. A matching shape alone does
not establish matching meaning. Preserve public interfaces and file ownership;
never overwrite user adapters with generated stubs.
