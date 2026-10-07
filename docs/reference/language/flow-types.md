---
id: lawspec.reference.language.flow-types
kind: reference
title: Flow types
---
# Flow types

A flow parameter `A / A'` takes a state at type `A` and leaves it at `A'`. It
follows Wilshaw and Hutton, *Flow Typing: A New Lens on Linearity* ref:wilshaw-hutton-flow-typing. In laws,
`~s` passes a state and rebinds it to the state the call leaves.

```lawspec
unit guide.flow

type Stack (n :: Natural) is
  | Empty where n = 0
  | Push top :: Int8 rest :: Stack m where n = m + 1
end

push :: (x :: Int8) -> Stack n / Stack (n + 1) -> Unit
pop :: Stack (n + 1) / Stack n -> Int8

definition pushed (x :: Int8) (s :: Stack n / Stack (n + 1)) :: Unit is
  ~s := Push x s
end

law `pop returns what push pushed` is
  definition is
    `for all` (x :: Int8) (s :: Stack n) . (push x ~s; pop ~s) = x
  end
end

law `pops come back in reverse` is
  definition is
    `for all` (x :: Int8) (y :: Int8) (s :: Stack n) .
      (push x ~s; push y ~s; pop ~s; pop ~s) = x
  end
end
```

## Syntax

| Form | Meaning |
| --- | --- |
| `A / A'` | a flow parameter; legal only as a signature argument. A function may take several |
| `~s` | pass the state `s` to a flow parameter, and rebind `s` to the state the call leaves |
| `e1; e2` | evaluate `e1`, then `e2`; the value is `e2`'s |
| `~s := e` | in a definition, update its flow parameter `s` (any of them, when it has several) |

A plain `s` reads the current state. `(push x ~s; nOfStack s) = n + 1` reads
the stack after the push.

A function with several flow parameters takes a state for each, and the call
rebinds each one:

```lawspec fragment
definition pushBoth (x :: Int8) (a :: Stack n / Stack (n + 1)) (b :: Stack m / Stack (m + 1)) :: Unit is
  ~a := Push x a; ~b := Push x b
end

law `both stacks get the value` is
  definition is
    `for all` (x :: Int8) (a :: Stack n) (b :: Stack m) . (pushBoth x ~a ~b; pop ~a; pop ~b) = x
  end
end
```

A state has one owner, so the same state cannot be passed to two flow
parameters of one call. A model's command still takes the model's state as
its one flow parameter.

## Flow calls in branches

A flow call may sit in a branch of an `if` or a `match`. Only the branch taken
runs, and the state continues from whichever branch ran:

```lawspec fragment
law `a push in each branch` is
  definition is
    `for all` (x :: Int8) (s :: Stack n) .
      ((if x > 0 then push x ~s else push 0 ~s); pop ~s) = (if x > 0 then x else 0)
  end
end
```

Every branch must leave the state at the same type for it to be used after
the branches. Here both push once, so `s` is a `Stack (n + 1)` afterwards and
`pop` can take it. If one branch pushed and the other did not, using `s`
afterwards is rejected: `after these branches, s is Stack (n + 1) in the then
branch, but Stack n in the else branch`. Using it only inside the branches is
fine.

## Typestate

Each law clause is checked left to right. Passing `~s` to `pop` matches the
state's type against `Stack (m + 1)`:

- after `push x ~s`, `s` is a `Stack (n + 1)`, so `m` is `n` and `s` becomes a
  `Stack n`;
- with `s :: Stack n` alone, `pop ~s` is rejected: `pop needs Stack (n + 1);
  the state is Stack n; add where n >= 1 to a quantifier, or quantify the state
  at an index of the form m + 1`. `(s :: Stack (k + 1))` is accepted.

Errors:

- a flow parameter given a plain value (`write ~s`);
- `~` on an argument that is not a flow parameter, or on a name that is not a
  quantified variable or parameter;
- a flow call after `&&` or `||`, or in an all-elements predicate, where it
  may not run;
- the same state passed to two flow parameters of one call;
- a state used after branches that leave it at different types;
- `~`, `;` or `:=` outside a law clause or definition body, such as in a
  refinement;
- a flow call in an implication's guard.

Index patterns are `v` or `v + k`; type arguments of the state may be type
variables.

## Desugaring and native shape

Each flow function returns a generated product named after it: `PushFlow` with
a `state` field, and `PopFlow` with `result` and `state` fields (a `Unit`
result has no field). A function with several flow parameters has a field per
state: `state1`, `state2`, and so on, in argument order. Branches that call
flow functions join their value and states in a generated `FlowJoinN`. Its index is the output state's, so an adapter that
leaves the wrong stack fails its postcondition (`RUNTIME CHECKED`). A
definition such as `pushed` returns its product too, and the index prover
checks it.

| Target | `pop`'s adapter returns |
| --- | --- |
| Java | `record PopFlow(Byte result, Stack state)` |
| Kotlin | `data class PopFlow(val result: Byte, val state: Stack)` |
| Go | `PopFlow{Result: ..., State: ...}` |
| Rust | `PopFlow { result, state }`; the state is taken by value |
| Haskell | `Data.PopFlow result state` |
| Python | `data.PopFlow(result, state)` |
| JavaScript, TypeScript | `new data.PopFlow(result, state)` |

A law's calls run in order, and each side of an equation repeats the calls
before it, so both sides see the same states.
