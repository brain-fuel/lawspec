---
id: lawspec.reference.language.syntax
kind: reference
title: Syntax
---
# Syntax

The current authoring profile is `1.0-rc.1`, through API schema 5 and
configuration version 2. The identifier is technical; the current authoring
milestone is a minor version, not a release candidate. The
[authoring contract](rc1.md) records its semantics and remaining gates.

## Grammar

These are the main canonical forms. Existing workflow, ability, handler,
resource, model, actor, scenario and harness declarations retain their forms;
their computations use the same canonical expressions. The legacy grammar
below is migration input, not an alternative normal parser.

```text
source       = "unit" qualified-name import* declaration*
annotation   = ("of" "type" | "::") type
signature    = name annotation requirements? effects?
function     = "function" name parameter+ "->" type requirements?
               "is" expression "end" "function"
procedure    = "procedure" name parameter+ ["->" type] requirements? effects?
               "is" expression "end" "procedure"
parameter    = "(" pattern annotation ["where" expression] ")"
record       = "type" name type-parameter* "is" "a" "record" "{"
               (name annotation [","])* "}" "end" "type"
alternatives = "type" name type-parameter* "is" "one" "of"
               (["|"] name [annotation] equations?)+ "end" "type"
case         = "first" "matching" "case" "of" expression ":"
               ("when" (pattern | "it" "matches" pattern | expression)
                ["if" expression] "then" expression)+
               ["otherwise" expression] "end" "case"
conditional  = "if" expression "then" expression "else" expression "end" "if"
universal    = "for" "all" parameter+ "=>" proposition "end"
existential  = "there" ["must"] "exist" parameter+ "such" "that" proposition "end"
             | "there" "exists" parameter+ "such" "that" proposition "end"
table        = ("expect" expression ["=" expected])+
               "in" "table" "(" name ("," name)* ")" ":"
               ("row" constant ("," constant)*)+ "end"
mapping      = "mapping" name annotation "is"
               ("row" constant "," constant)+ ["otherwise" constant]
               "end" "mapping"
```

A law uses `law name is`, optional scalar metadata, its sections and examples,
then `end`. Every ordinary law has exactly one `definition:` section.
`description:`, `rationale:` and `references:` are optional singleton sections;
named examples and expectation tables may repeat. Every section has its own
`end`; scalar metadata has none. Formatting preserves section order.

Function results use `->`; a procedure returning `()` may omit its result.
Alternatives have no payload or one explicitly annotated payload; records and
tuples group multiple components. Named records construct as `Name record{...}`;
record values and patterns use comma-separated `field = value` entries.

Phrase names start with `"|` and end with `|`, without a closing quote. Named
infix application starts with a backtick and optionally uses pipe delimiters.
Prefix and infix calls share resolution and one function namespace. Comparisons
and matchers bind above canonical equality, then worded `not`, conjunction,
disjunction and right-associative `implies`. Existing symbolic operator order
stays intact; `a = b && c = d` compares both pairs. Named-infix chains and
equality chains require parentheses where they would be ambiguous.

The current minor still has plain endings for laws, sections, quantifiers and
other existing blocks. The following minor requires named endings for every
block and must reject bare `end`.

## Legacy 0.24 syntax

The following reference preserves the prior forms for explicit migration.
See [source migration](../../explanation/api-migration.md#source-migration-from-024)
for checked previews, correspondence limits and project writes.

### Units

A source file declares one unit, named on its first line. The unit's imports
follow, then its declarations in any order:

```lawspec
unit example.atoi_codec

itoa :: Int32 -> Text
atoi :: Text -> Int32

law `round trip` is
  definition is
    `left inverse` atoi itoa
  end
  description is
    "applying {itoa} and then {atoi} recovers the original integer"
  end
  example `negative integers use a minus sign and round-trip unchanged` is
    x = -42
    expect itoa x = "-42"
    expect atoi (itoa x) = -42
  end
end
```

The qualified unit name determines the module or package path on every target.
Names are scoped to their unit.

### Declarations

A unit can contain:

| Declaration | Form | Reference |
| --- | --- | --- |
| Function signature (an adapter you implement) | `name :: Type -> Type` | [Laws and examples](laws-and-examples.md) |
| Data type | `type Name ... is ... end` | [Types and data](types-and-data.md) |
| Indexed family | `type Vec (n :: Natural) (a :: Type) is ... end` | [Indexed families](indexed-families.md) |
| Wrapper | `wrapper Name is Type where ... end` | [Domain modeling](domain-modeling.md) |
| Workflow | `workflow name :: A -> B is ... end` | [Workflows](workflows.md) |
| Checked definition | `definition name (x :: T) :: R is ... end` | [Definitions](definitions.md) |
| Refinement | `refinement Name ... is ... end` | [Refinements](../refinements.md) |
| Law | ``law `name` is ... end`` | [Laws and examples](laws-and-examples.md) |

Function signatures are curried: `a -> b -> c` takes two inputs and returns a
`c`. Functions are synchronous. They can take any positive number of arguments.

### Lexical rules

- `--` starts a comment that runs to the end of the line.
- Law and example names are quoted with backticks: `` `round trip` ``.
- Text literals use double quotes, with escapes such as `\"`, `\\`, `\n` and
  `\t`. Text contains Unicode scalar values; surrogate code points are rejected.
- Descriptions and rationales can refer to functions as `{itoa}`. Write `{{`
  and `}}` for literal braces.
- Lowercase type names are type variables. `(a :: Type)` declares a type
  parameter, not a runtime value.
- Qualified names have no spaces around the dot (`domain.Usd`); composition is
  written with spaces (`f . g`).
- Names that cannot be emitted portably on every target are diagnosed.
- A definition or adapter named with a keyword of a target language is emitted
  in that target with a leading underscore, and keeps its name elsewhere. A
  definition `short` is `_short` in Java; an adapter `class` is written as
  `_class` in Python, JavaScript, TypeScript, Java, Kotlin and Haskell, `class`
  in Rust, and `Class` in Go, whose exported names are capitalized. Laws,
  messages and evidence use the declared name. The [keywords
  example](../../../examples/specs/keywords.lawspec) shows each case.

The following words are reserved:

```text
unit law requires is end definition description rationale example expect
implies and true false references are Eq where refinement type match with
```

`import`, `as`, `wrapper` and `workflow` begin imports and declarations.

### Law blocks

A law's blocks come in this order:

1. `definition is ... end`: the proposition (required);
2. `description is "..." end` (optional);
3. `rationale is "..." end` (optional);
4. any number of `example` blocks;
5. `references are "..." "..." end` (optional).

### Legacy grammar

This grammar summarizes the main forms. The parser and the compiler's tests
specify the lexical details.

```text
source       = "unit" qualified-name import* declaration*
import       = "import" qualified-name ["as" name]
               ["(" (name | quoted-name) ("," (name | quoted-name))* ")"]
declaration  = name "::" type | law | refinement | data-type | wrapper
             | workflow | function
data-type    = "type" name ("(" name "::" ("Type" | "Natural") ")")*
               "is" constructor* "end"
constructor  = ["|"] name (name "::" type)*
               ["where" name "=" expression ("," name "=" expression)*]
wrapper      = "wrapper" name ("(" name "::" "Type" ")")*
               "is" type ["where" expression] "end"
workflow     = "workflow" name "::" type "is" (stage policy*)+ "end"
stage        = name "::" type
             | ("then" | ">>=") name ["::" type]
             | ("map" | "<$>" | "mapError" | "<!>" | "tap") name
             | ("orElse" | "recover" | "<|>" | "fallback" | "??") name
             | "ensure" name "else" name
             | "all" ["accumulate"] (name "::" type | ("then" | ">>=") name)+
               "end" "combine" name
policy       = "retry" strategy ["jitter" ("full" | "equal" | "decorrelated")]
               ["when" name]
             | "timeout" duration ["else" name]
             | "rateLimit" ("tokenBucket" | "leakyBucket" | "fixedWindow"
               | "slidingWindow") count duration wait ["else" name]
             | "circuitBreaker" count duration "cooldown" duration ["else" name]
             | "bulkhead" count wait ["else" name]
             | "cache" duration
             | "compensate" name
             | "hedge" duration ["max" count]
strategy     = "immediate" count | "fixed" duration count
             | "linear" duration duration count
             | "exponential" duration count count ["max" duration]
             | "fibonacci" duration count | "custom" name [count]
wait         = "wait" ["max" duration] | "reject"
function     = "definition" name parameter+ "::" type requirements?
               "is" expression "end"
type         = type-atom ["->" type]
type-atom    = primitive | type-variable | "(" type ")"
             | ("Nullable" | "Optional" | "List" | "Maybe") type-atom
             | "Either" type-atom type-atom
             | data-type-name type-atom*
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
description  = "description" "is" string "end"
rationale    = "rationale" "is" string "end"
references   = "references" "are" string+ "end"
proposition  = "`for all`" parameter+ "." proposition
             | expression "=" expression
             | expression "implies" proposition
             | proposition "and" proposition
             | quoted-name expression* | expression
expression   = ... | "[" [expression ("," expression)*] "]"
             | constructor-name expression*
             | "match" expression "with"
               ("|" constructor-name name* "->" expression)+ "end"
example      = "example" quoted-name "is" (name "=" literal)+
               ("expect" expression "=" literal)+ "end"
```

Expression precedence and literals are described in
[expressions and arithmetic](expressions-and-arithmetic.md).

## Canonical positional products

The authoring minor's explicit `1.0-rc.1` language profile adds tuple types,
values and recursive patterns together. The profile identifier is a technical
interface identifier; it does not designate a release candidate.

```text
function width ((width, _) of type (Nat, Nat)) -> Nat is
  width
end function

function label (value of type (Integer, Bool)) -> Integer is
  first matching case of value:
    when (number, true) then number
    when (_, false) then 0
  end case
end function
```

Tuple components are distinguished by position. A tuple has at least two
components; `()` retains its Unit meaning, and `(value)` remains grouping.
Arity and nesting are significant: `(A, B, C)` differs from `(A, (B, C))`.
Tuples are closed structural products, distinct from the nominal prelude
`Pair` and named records. There is no implicit nominal conversion.

Components evaluate from left to right, once each. Tuple patterns require the
same arity as their selected type, including when an earlier row makes the
pattern unreachable. Records, tuples and alternative payloads may nest.

Canonical functions and procedures also accept irrefutable record, tuple and
constructor parameter patterns. An identifier directly before its annotation
remains a binding, including uppercase locals; parenthesize a payload-free
constructor to select a constructor pattern. The ordinary exhaustiveness checker rejects
refutable constructors. Bindings may not repeat across parameters. Destructured
names remain available in the parameter's `where` restriction, later parameter
restrictions, the result contract and body. Automatic definition validation,
including definedness and termination, remains mandatory.

The current minor retains its existing law, section and quantifier endings.
The following minor milestone requires named closers for every block and must
reject bare `end`.

## Typing case branches

Guards and bodies must type-check in their branch scopes even when an earlier
row covers their pattern. A guard must be Boolean; each result must fit the
case's result type. Pattern bindings stay local to their own branch. The
ordinary GADT rules for inaccessible constructors continue to apply.

This function has a type error in its discarded row:

```text
function decision (value of type Bool) -> Bool is
  first matching case of value:
    when #any then true
    when true then 7
  end case
end function
```

Discarded branches do not execute. Destructuring needs no Eq capability; an
equality operation in a discarded generic body still needs Eq. Mandatory
definition typing, definedness and termination checks remain independent of
the selected law-verification layers.
