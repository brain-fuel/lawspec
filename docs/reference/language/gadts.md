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

type Pair (a :: Type) (b :: Type) is a record{  first :: a second :: b} end type

type Expr (a :: Type) is one of
  | Number  of type Integer where a = Integer
  | Truth  of type Bool where a = Bool
  | Same of type record{ left :: Expr Integer right :: Expr Integer} where a =
  Bool
  | Both of type record{ first :: Expr b second :: Expr c} where a = Pair b c
end type

function eval (e :: Expr a) -> a is
  first matching case of e :
    when Number v then v
    when Truth b then b
    when Same record{ left = l , right = r} then eval l = eval r
    when Both record{ first = l , second = r} then Pair record{ first = (eval l)
        , second = (eval r)}
  end case
end function

evalTruth :: Expr Bool -> Bool

law "|truths agree with eval| is
  definition : for all (e :: Expr Bool) => evalTruth e = eval e end end
end
```

## Refinement

- In the `Number` branch, `a` is `Integer`, so `v` is a value of `a`.
- A constructor that cannot build a type is no value of it: `Expr Bool` has
  only `Truth` and `Same`. A match at that type needs no other branch, and a
  construction at the wrong type is an error.
- `eval` calls itself at other instances (`eval l` is at `Expr Integer` inside
  `Same`). Each instance it is used at becomes a checked instance, up to 64 per
  definition.

## Payloads determined by indices

A constructor equation constrains occurrences of the index in its payload as
well as its result. In the canonical
[indexed-reading fixture](../../../test/fixtures/canonical-gadt-payload-indices.lawspec),
`Counter of type a where a = UInt8` takes a UInt8 payload. `Details` fixes the
same parameter to `record{value of type UInt8}`, so a generic match can
destructure that record and read its field. Those facts remain local to each
branch. A wrong payload, out-of-range literal or incompatible result is rejected
during mandatory definition admission, including with no law checks selected.
Concrete structural indices compare fields by label and retain their complete
restrictions.

Two indices can share a determined existential, as in `a = List c, b = c`.
The payload and result use that same `c`; construction cannot choose unrelated
payload types. This differs from a field-only existential whose type is known
only through its value's witness.

## Existentials

A type variable in a constructor that is not a parameter is existential.

- In `Both`, `b` and `c` are determined by the type: `Expr (Pair b c)`.
- A variable that only a field mentions is fixed by each value.
  For example, `type Shown is one of | Shown of type b end type`.
  Each value carries its type as a **witness**: a trailing `witness` field holding the type's name, such as
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

Generated sum cases use their fixed index types in their native fields. A
single-constructor product retains its public type parameters; its codec checks
the constructor equations. Python bases use forward references when an index
names a data type declared later. Haskell's derived display instance can require
`Show` for a result parameter that directly determines an existential payload.
These native display constraints do not add a LawSpec `Eq` requirement.
