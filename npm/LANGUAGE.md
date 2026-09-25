# LawSpec language and compiler boundary (0.8)

LawSpec describes portable laws, concrete examples, and adapter contracts. The
compiler is written in Haskell. Rust is an output backend alongside Java, Python,
JavaScript, TypeScript, Go, Haskell, and Kotlin.

## Source and declarations

A source has one named `unit`, function signatures, reusable refinements, and
laws. Qualified unit names determine target module/package paths. Function
signatures are curried: `a -> b -> c` takes two inputs and returns `c`. Parentheses
group types and expressions. Comments start with `--` and run to the line end.

The following grammar summarizes the main forms; the parser and executable
compiler tests specify lexical details:

```text
source       = "unit" qualified-name declaration*
declaration  = name "::" type | law | refinement
type         = type-atom ["->" type]
type-atom    = primitive | type-variable | "(" type ")"
             | ("Nullable" | "Optional") type-atom
             | refinement-name argument*
             | "(" name "::" type ["where" expression] ")"
refinement   = "refinement" name parameter* requirements?
               "is" type "end"
parameter    = "(" name "::" type ["where" expression] ")"
requirements = "requires" (capability type)+
capability   = "Eq" | "Integer" | "Ordered" | "Bounded"
law          = "law" quoted-name parameter* requirements? "is"
               "definition" "is" proposition "end"
               description? rationale? example* references? "end"
proposition  = "`for all`" parameter+ "." proposition
             | expression "=" expression
             | expression "implies" proposition
             | proposition "and" proposition
             | quoted-name expression* | expression
example      = "example" quoted-name "is" (name "=" literal)+
               ("expect" expression "=" literal)+ "end"
```

Law names use backticks. Text/metadata use double quotes with escapes. Named
refinement declarations state their type versus value parameter kinds, including
forward references; the compiler validates their arity and argument kinds.
Lowercase type names represent variables. `a :: Type` is a type parameter, not a
runtime value with a generator.

A generic law is specialized when invoked with concrete adapters. Its declared
capabilities must justify its operations; specialization resolves those
requirements for the actual types. `Integer` as a capability requires an integer
type. `Integer` in a concrete result signature denotes a representation-independent
mathematical integer. See [refinements and abstract integers](REFINEMENTS.md).

## Expressions and arithmetic

Application binds most tightly. The remaining precedence, highest first, is:
unary `!`/`-`, composition `.`, multiplication/division, addition/subtraction,
comparisons (`==`, `!=`, `<`, `<=`, `>`, `>=`), `&&`, then `||`.
Comparisons do not chain. Arithmetic associates left; composition associates
right. An adjacent numeric sign remains part of an argument: `f -42` applies `f`
to negative 42. Write `x - 42` for subtraction.

Assertion `=` differs from Boolean `==`. `implies` guards its following
proposition; `and` requires both assertions. Parentheses determine the scope of a
shared guard. Both Boolean operators and implications short-circuit.

Literals acquire types from declared context. Unconstrained integers have type
`Integer`; decimal tokens have type `Decimal`. An annotation such as
`(127 :: Int8)` specifies context. A declared float context can type a decimal
token directly, but an explicitly constructed exact Decimal is not implicitly
converted into a float.

Integer `+`, `-`, `*`, and negation produce exact `Integer` results. Decimal
dominates integer/Decimal combinations; Rational dominates exact combinations
involving Rational. Exact `/` returns Rational. `prelude.quot` truncates integer
quotients toward zero; `prelude.rem` is the associated remainder. Division by
zero fails when evaluated. Explicit numeric conversions use `prelude.Type`.
Exact/inexact mixing otherwise fails type checking. IEEE arithmetic widens float
or complex precision as required; equality treats NaN as unequal and signed
zero as equal. Decimal rounding is explicit, with a scale and ties-to-even rule.

Passing a computed exact result to a bounded adapter argument performs a checked
conversion. It never wraps, truncates a fraction, or silently changes precision.
Adapter results are validated against the declared domain before use. See the
[primitive reference](PRIMITIVES.md) for all domains and helpers.

## Refinements and executable contracts

Refinements are pure Boolean predicates over a value and preceding binders.
They cannot call user adapters. Dependent inputs are generated in order;
shrinking preserves their predicates. Bounds such as `y > Int8.max - x` are
computed with exact arithmetic and can drive a dependent generator. If a chosen
`x` has no possible `y`, generation retries earlier inputs. Search exhaustion
fails explicitly rather than passing a property with no valid cases.

Contracts check preconditions, evaluate an adapter once, validate the result,
and then check postconditions against that same result. Predicate errors are
contextual failures, not rejected samples. Small finite domains are enumerated;
other domains use target property frameworks. `machineBits: 32 | 64` controls
machine-integer domains independently of the compiler host architecture. Native
machine-sized adapter bindings additionally verify the executing architecture.

## Compiler stages and public API

The parser retains source ranges. Resolution and inference check names, kinds,
capabilities, contextual literals, and generic specializations. Elaboration
produces typed core expressions with resolved declaration/binder IDs, explicit
arithmetic evidence and conversions, plus an authoritative proposition tree.
Refinement declarations become predicates on quantifiers and contracts; targets
do not interpret refinement syntax.

An independent core validator checks scopes, kinds, operand/result types,
capability evidence, and conversions. A pure core evaluator supports deterministic
domain checks and reference tests. The testing planner computes finite cases,
boundaries, and dependent generator requirements. All eight emitters consume
that plan and the core, without importing source syntax or inference.

`check`/`expand` report semantic validity. `planGeneration` additionally reports
execution feasibility, including empty finite domains. Source syntax errors,
semantic errors, core invariant failures, and generation errors have distinct
diagnostic codes. Runtime failures identify the law/example or adapter contract.
Parsed expressions retain real source ranges; synthesized expressions identify
the declaration that caused their creation.

API schema v3 uses separately defined wire views, with lossless tagged scalar
values. It does not serialize internal AST constructors. See the
[API migration guide](API-MIGRATION.md).

## Next language features

`List`, algebraic `Maybe`/`Either`, user-defined sums and products, pattern
matching, GADTs, and general dependent types are outside 0.8. The core type model
supports arbitrary constructor arity and distinguishes type and index arguments
so those features can be added without target-specific surface interpretation.
`Nullable` and `Optional` retain their interoperability semantics; they do not
stand in for future algebraic sum types.
