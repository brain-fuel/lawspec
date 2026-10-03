# Syntax

## Units

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

## Declarations

A unit can contain:

| Declaration | Form | Reference |
| --- | --- | --- |
| Function signature (an adapter you implement) | `name :: Type -> Type` | [Laws and examples](laws-and-examples.md) |
| Data type | `type Name ... is ... end` | [Types and data](types-and-data.md) |
| Indexed family | `type Vec (n :: Natural) (a :: Type) is ... end` | [Indexed families](indexed-families.md) |
| Wrapper | `wrapper Name is Type where ... end` | [Domain modeling](domain-modeling.md) |
| Workflow | `workflow name :: A -> B is ... end` | [Domain modeling](domain-modeling.md) |
| Checked definition | `definition name (x :: T) :: R is ... end` | [Definitions](definitions.md) |
| Refinement | `refinement Name ... is ... end` | [Refinements](../refinements.md) |
| Law | ``law `name` is ... end`` | [Laws and examples](laws-and-examples.md) |

Function signatures are curried: `a -> b -> c` takes two inputs and returns a
`c`. Functions are synchronous. They can take any positive number of arguments.

## Lexical rules

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

## Law blocks

A law's blocks come in this order:

1. `definition is ... end`: the proposition (required);
2. `description is "..." end` (optional);
3. `rationale is "..." end` (optional);
4. any number of `example` blocks;
5. `references are "..." "..." end` (optional).

## Grammar

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
workflow     = "workflow" name "::" type "is" stage+ "end"
stage        = name "::" type
             | ("then" | ">>=") name ["::" type]
             | ("map" | "<$>" | "mapError" | "<!>" | "tap") name
             | ("orElse" | "recover" | "<|>" | "fallback" | "??") name
             | "ensure" name "else" name
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
