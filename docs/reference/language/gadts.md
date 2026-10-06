---
id: lawspec.reference.language.gadts
kind: reference
title: GADTs
---
# GADTs

A constructor can fix a type parameter with `where`. It then builds values of
that instance only, and matching on it refines the parameter in that branch.

```lawspec
unit guide.gadts

type Pair (a :: Type) (b :: Type) is Pair first :: a second :: b end

type Expr (a :: Type) is
  | Number value :: BigInt where a = BigInt
  | Truth value :: Bool where a = Bool
  | Same left :: Expr BigInt right :: Expr BigInt where a = Bool
  | Both first :: Expr b second :: Expr c where a = Pair b c
end

definition eval (e :: Expr a) :: a is
  match e with
  | Number v -> v
  | Truth b -> b
  | Same l r -> eval l == eval r
  | Both l r -> Pair (eval l) (eval r)
  end
end

evalTruth :: Expr Bool -> Bool

law `truths agree with eval` is
  definition is `for all` (e :: Expr Bool) . evalTruth e = eval e end
end
```

## Refinement

- In the `Number` branch, `a` is `BigInt`, so `v` is a value of `a`.
- A constructor that cannot build a type is no value of it: `Expr Bool` has
  only `Truth` and `Same`. A match at that type needs no other branch, and a
  construction at the wrong type is an error.
- `eval` calls itself at other instances (`eval l` is at `Expr BigInt` inside
  `Same`). Each instance it is used at becomes a checked instance, up to 64 per
  definition.

## Existentials

A type variable in a constructor that is not a parameter is existential.

- In `Both`, `b` and `c` are determined by the type: `Expr (Pair b c)`.
- A variable that only a field mentions is fixed by each value, as in
  `type Shown is | Shown value :: b end`. Each value carries its type as a
  **witness**: a trailing `witness` field holding the type's name, such as
  `"Int32"` or `"(Pair Bool Int32)"`. Generated values take their witness from
  `Bool` and `Int32`. A definition cannot match such a constructor; adapters
  read the witness natively. A field of such a constructor cannot itself be
  named `witness`.

## Native types

| Target | `Expr` | Field-only existential |
| --- | --- | --- |
| Java | sealed interface `Expr<A>`; `record Number(BigInteger value) implements Expr<BigInteger>` | `Object` field and `String witness` |
| Kotlin | `sealed interface Expr<A>`; `data class Number(val value: BigInteger) : Expr<BigInteger>` | `Any?` field and `val witness: String` |
| Haskell | GADT syntax: `ExprNumber :: Integer -> Expr Integer` | existential field and `Text` witness |
| TypeScript | a conditional union over `A` | `unknown` field and `witness: string` |
| Python | `class ExprNumber(Expr[int])` | `witness: str` |
| Go, Rust | the type argument is erased and checked by the schema; existential fields are dynamic values | `Witness string` / `witness: String` |

Decoding checks that a value's constructor can build the expected type, so an
adapter cannot return `Number` where `Expr Bool` is expected.
