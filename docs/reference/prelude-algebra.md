# Prelude laws and algebra

The prelude is an implicit unit, `prelude`, available in every source. It
defines reusable laws and the semantics of currying, conjunction, implication
and expected results.

## Prelude laws

### Functions and round trips

| Law and arguments | Checks, for every input | Requires |
| --- | --- | --- |
| `left inverse f g` | `f (g x) = x` | `Eq` on `x` |
| `round trip identity is preserved a b` | `b (a x) = x` | `Eq` on `x` |
| `equivalent f g` | `f x = g x` | `Eq` on the result |
| `idempotent f` | `f (f x) = f x` | `Eq` |
| `satisfies predicate` | `predicate x` is true | |
| `left inverse when predicate f g` | `predicate x implies f (g x) = x` | `Eq` on `x` |
| `involution f` | `f (f x) = x` | `Eq` |

`equivalent` can compare two predicates, because `Bool` has equality.
`satisfies` and `left inverse when` keep their condition, and its bindings, when
they are expanded.

### Algebra

`f` and `g` are binary operations, `inverse` is unary, and `e` and `zero` are
values. All of these laws require equality on the element type.

| Law and arguments | Equations checked for every quantified input |
| --- | --- |
| `commutative f` | `f x y = f y x` |
| `associative f` | `f (f x y) z = f x (f y z)` |
| `left identity f e` | `f e x = x` |
| `right identity f e` | `f x e = x` |
| `identity f e` | Both identity equations |
| `left absorbing element f zero` | `f zero x = zero` |
| `right absorbing element f zero` | `f x zero = zero` |
| `absorbing element f zero` | Both absorbing equations |
| `left distributive f g` | `f x (g y z) = g (f x y) (f x z)` |
| `right distributive f g` | `f (g x y) z = g (f x z) (f y z)` |
| `distributive f g` | Both distributive equations |
| `idempotent operation f` | `f x x = x` |
| `left inverse element f inverse e` | `f (inverse x) x = e` |
| `right inverse element f inverse e` | `f x (inverse x) = e` |
| `invertible f inverse e` | Both inverse equations |
| `left division f divideLeft` | `f x (divideLeft x y) = y` and `divideLeft x (f x y) = y` |
| `right division f divideRight` | `f (divideRight x y) y = x` and `divideRight (f x y) y = x` |
| `divisible f divideLeft divideRight` | All four division equations |

`idempotent operation` is the binary form; `idempotent` is unary.

**Divisible** means algebraic left and right division: `divideLeft x y` solves
`f x result = y`, and `divideRight x y` solves `f result y = x`. For a
non-commutative operation such as subtraction, with `x = 3` and `y = 5`, the
left solution is `-2` and the right solution is `8`. Recovery is checked in both
directions. These are total laws: a partially defined division needs an explicit
domain predicate and conditional equations.

`invertible` checks the supplied inverse. To specify a group, also check
`identity` and `associative`. The prelude states contracts; it does not supply
arithmetic implementations, and random tests do not prove that a structure is a
group.

Every row has an executable example in
[`algebra.lawspec`](../../examples/specs/algebra.lawspec), including both sides
of every combined law. Its examples use exact `Integer` values whose expected
results exceed `Int32` and machine bounds, so an adapter that wraps fails even
when modular arithmetic happens to satisfy the identities.

### Collection operations

`prelude.setOf`, `prelude.lookup`, `prelude.push` and the other collection
operations, and `prelude.compare`, are listed in
[collections](language/collections.md#operations).

## Currying and partial application

Arrows associate to the right and application to the left: `f :: a -> b -> c`
takes two arguments, and `f x y` means `(f x) y`.

```lawspec
unit example.addition

add :: Int32 -> Int32 -> Int32

law `addition commutes` is
  definition is
    `commutative` add
  end

  example `3 plus 5 and 5 plus 3 both produce 8` is
    x = 3
    y = 5
    expect add x y = 8
    expect add y x = 8
  end
end

law `zero is an identity on both sides` is
  definition is
    `identity` add 0
  end

  example `zero preserves 3 on either side` is
    x = 3
    expect add 0 x = 3
    expect add x 0 = 3
  end
end
```

- A partial application such as `add 1` can be passed to a unary law, and
  `sumFour 1 2` to a binary law. Partial applications also compose.
- Value parameters take literals directly: `` `left identity` add 0 ``, or
  `` `absorbing element` multiply 0 ``.
- The compiler specializes these expressions before emitting code.

Adapters take ordinary positional arguments (`add(x, y)`) in Java, Kotlin,
Python, JavaScript, TypeScript, Go and Rust, and curried arguments (`add x y`)
in Haskell. Argument order and types are preserved, including mixtures such as
`Text`, `Bool` and `Int32`.

The [currying example](../../examples/specs/currying.lawspec) partially applies
a four-argument function twice, formats four arguments of different types, and
composes after partial application, with exact expected outputs.

## Conjunction

`and` requires several conclusions in one law:

```lawspec
unit example.absorption
multiply :: Int32 -> Int32 -> Int32

law `zero absorbs on both sides` is
  definition is
    `for all` (x :: Int32) .
      multiply 0 x = 0 and multiply x 0 = 0
  end

  example `3 times zero and zero times 3 both produce zero` is
    x = 3
    expect multiply 0 x = 0
    expect multiply x 0 = 0
  end
end
```

Quantification and implication extend over a following `and`:
`p x implies A and B` guards both conclusions. Write `(p x implies A) and B` to
guard only the first. A shared guard runs once per check, and a false guard
skips its whole consequence. Every conjunct is type-checked and emitted; within
one test, the first failing conjunct stops that test.

`lawspec explain` prints the whole conjunction and the scope of each condition.
In the API, a law's `assertion` tree is authoritative; see
[the API reference](api.md#laws-and-assertions).

## Predicates and implication

A predicate is a function returning `Bool`. `true` and `false` can appear in
expressions, example bindings and expected results. A Boolean expression on its
own is a law definition that must be `true`.

`condition implies consequence` checks the consequence only when the condition
is true. The condition must be a `Bool`. The consequence can be an equality,
another implication, a Boolean predicate or a reusable law. Nested implications
short-circuit in source order. Quantify inputs before using them.

```lawspec
unit example.parse_port

validPort :: Int32 -> Bool
render    :: Int32 -> Text
parse     :: Text -> Int32

law `valid ports round trip` is
  definition is
    `for all` (x :: Int32) .
      validPort x implies
        parse (render x) = x
  end

  example `ordinary port` is
    x = 443
    expect validPort x = true
    expect render x = "443"
    expect parse (render x) = 443
  end

  example `zero is rejected; the round trip is skipped` is
    x = 0
    expect validPort x = false
  end
end
```

- Explicit `expect` assertions always run, whatever the condition. A false
  condition skips only the law's consequence: invalid ports never reach
  `render` or `parse` through the law.
- An error raised by the predicate fails the test. It is not treated as false.
- Implication is logical implication, not generator filtering. Random tests
  still sample the whole input domain and count a false condition as
  satisfying the law. A narrow predicate may exercise few consequences in a
  random run, so add explicit examples for the important cases. Examples that
  expect both `true` and `false` catch predicates that are always one or the
  other.

The [complete port example](../../examples/specs/parse_port.lawspec) treats
1–65535 as valid and covers both endpoints, zero, negative values and 65536. The
[Boolean flags example](../../examples/specs/boolean_flags.lawspec) checks that
flipping twice restores both `false` and `true`.

## Expected results

Every `example` binds all the law's quantified inputs, then states one or more
results with `expect <expression> = <literal>`.

- The literal must have the expression's type.
- Expressions can use the example's inputs and the unit's functions, including
  compositions. Input names shadow function names.
- Expected results are written by you. They are never inferred by running
  your adapter.
- An example passes only when **all its expected results and the enclosing
  law** hold for its inputs. Random and boundary tests continue to check the
  general law.
- A failing assertion shows the compared values, and names the example, its
  input bindings and the expression. It stops that test only; other tests run
  independently.

A law may have no examples at all, but an example must have at least one
`expect`. Use `lawspec explain` to see a law's expansion, the input names its
examples must bind, and the expected results, without running any adapter.
