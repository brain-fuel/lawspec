---
id: lawspec.reference.language.syntax
kind: reference
title: Syntax
---
# Syntax

The grammar profile is `1.0-rc.2`. Every keyword-delimited block has a
mandatory named ending. This applies to compiler-owned sources as well as
application specifications. Pre-1.0 migration and compatibility grammars are
not provided.

## Blocks and endings

| Construct | Required ending |
| --- | --- |
| `unit` | `end unit` |
| `function` | `end function` |
| `procedure` | `end procedure` |
| `type` | `end type` |
| `refinement` | `end refinement` |
| `wrapper` | `end wrapper` |
| `law` | `end law` |
| `definition` | `end definition` |
| `description` | `end description` |
| `rationale` | `end rationale` |
| `references` | `end references` |
| `example` | `end example` |
| `table` | `end table` |
| `for all` | `end for all` |
| `exists` | `end exists` |
| `given` | `end given` |
| `case` | `end case` |
| `if` | `end if` |
| `let` | `end let` |
| `mapping` | `end mapping` |
| `workflow` | `end workflow` |
| `all` | `end all` |
| `protocol` | `end protocol` |
| `scenario` | `end scenario` |
| `par` | `end par` |
| `or else` | `end or else` |
| `model` | `end model` |
| `actor` | `end actor` |
| `supervisor` | `end supervisor` |
| `ability` | `end ability` |
| `laws` | `end laws` |
| `handler` | `end handler` |
| `handlers` | `end handlers` |
| `operation` | `end operation` |
| `handle` | `end handle` |
| `resource` | `end resource` |
| `acquire` | `end acquire` |
| `release` | `end release` |
| `reset` | `end reset` |
| `harness` | `end harness` |
| `for law` | `end for law` |
| `for laws` | `end for laws` |
| `strategy` | `end strategy` |
| `bind` | `end bind` |
| `benchmark` | `end benchmark` |

The table identifies block kinds. A first-matching case starts with
`first matching case of`; every existential wording starts with `there` and
closes with `end exists`. Recovery starts with `or else`. Handler sets start
with `handlers`; handled expressions start with `handle`.

A closer names its construct, independently of its declared name. Its complete
phrase must occupy one physical line, with spaces or tabs between words. A
trailing comment is allowed. Bare `end`, missing labels, unknown labels,
mismatched labels and closers without an opener are errors. Diagnostics identify
the offending location and, where available, the opener. The parser collects
independent errors at recoverable boundaries instead of stopping at the first
one. Each diagnostic retains its source location; malformed quotation or block
structure can prevent reliable recovery of later syntax. Recovery is for
reporting only and never admits a partial specification.

Parentheses, record braces, list brackets and set braces remain explicit
punctuation delimiters. Case arms, conditional arms and parallel branches are
clauses inside their enclosing block. Scalar metadata, signatures, alternative
constructors, mapping/table rows and individual settings are single entries.
A guarded `when` has a condition after `if`; a conditional expression has its
own `end if`.

## Units and declarations

```text
source       = unit | harness
unit         = "unit" qualified-name import* declaration* "end" "unit"
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
```

A unit keeps its `unit qualified.name` header and always ends with `end unit`.
Declarations use `is`; named law sections use `:`. Function results use `->`;
a procedure returning `()` may omit its result annotation. A `function` is pure;
a `procedure` may use declared abilities. Definition validation always runs.

Named records construct as `Name record{field = value}`. Record values and
patterns use comma-separated entries. Record types accept optional field
commas; formatting omits those separators. Anonymous records use `record{...}`.
An alternative has no payload or one explicitly typed payload; records and
tuples group multiple components.

Phrase names start with `"|` and end with `|`, without a closing quote.
Named infix application starts with a backtick and optionally uses pipe
delimiters. Prefix and infix calls share one function namespace. Dots outside
phrase delimiters qualify names; dots inside them belong to the phrase.

## Laws and quantifiers

```text
law example is
  description:
    "Every Boolean value has an equal witness."
  end description
  definition:
    for all (value of type Bool) =>
      there exists (answer of type Bool) such that
        answer must be value
      end exists
    end for all
  end definition
end law
```

Every ordinary law has exactly one `definition:` section. `description:`,
`rationale:` and `references:` are optional singleton sections; named examples
and expectation tables may repeat. Scalar `id:` and `owner:` metadata precede
sections and have one value with no separate ending. Formatting preserves
section order.

`there exists`, `there must exist`, `there does not exist` and
`there must not exist` all close with `end exists`. Their existing positive or
negative meanings are unchanged. Business `given` / optional `when` / `then`
scopes close with `end given`.

`must be`, `is`, `=`, `must =` and prefix `must` retain their typed equality
meaning. `must be` is preferred wording. Comparisons and named infix calls bind
above worded `not`, followed by `and`, `or` and right-associative `implies`.
Restrictions remain Boolean predicates; line breaks do not add obligations.

## Cases, bindings and mappings

```text
first matching case of value:
  when Pattern if condition then result
  otherwise fallback
end case

let value = expression in
  body
end let

mapping compText of type Comp -> Text is
  row CZero, "0"
  row COne, "1"
end mapping

expect doubleValue value = expected
in table (value, expected):
  row -1, -2
  row 0, 0
  row 1, 2
end table
```

Cases evaluate their selected expression once, try branches in order and scope
`it` to the selected value. Failed guards continue matching. `otherwise` is
unique and last. Every conditional expression closes with `end if`.

Mapping rows contain checked constants. Duplicate or non-reflexive keys are
rejected. Complete finite coverage or an explicit `otherwise` is required;
partial lookup is explicitly Maybe-valued. Derivations remain checked functions.

## Abilities, handlers and harnesses

```text
ability Meter is
  next of type Integer -> Integer
  laws
    law preservesValue is
      definition:
        for all (value of type Integer) => next value = value
        end for all
      end definition
    end law
  end laws
end ability

handler identityMeter for Meter is
  operation next value is
    value
  end operation
end handler
```

Every handler clause requires `operation`, including delegation:
`operation next by referenceNext end operation`. Ability operation signatures
have no body. A handler's optional state initializer belongs to its header.

Harness `for law` and `for laws` groups close with `end for law` and
`end for laws` respectively. Strategies close with `end strategy`; nested
`bind ... from ... in ...` generators close with `end bind`. A standalone
harness has `end harness` and no surrounding unit.

Workflow concurrent groups close before their combination:
`all ... end all combine functionName`. Scenario parallel groups use
`par ... with ... end par`; recovery uses `or else ... end or else`.
Resource acquisition, release and reset each have their own ending before
`end resource`.
