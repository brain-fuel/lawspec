# Randomness

`lawspec.randomness` has two abilities: `Random`, whose draws are
reproducible, and `SecureRandom`, the operating system's cryptographically
secure generator. They are separate abilities on purpose: a seeded source
can never answer where code needs a secure one. It is one of the [built-in
abilities](builtins.md).

```lawspec
unit guide.dice

import lawspec.randomness

-- A die: reproducible under a seed.
definition roll (sides :: Int64 where sides >= 1) :: Integer uses Random is randomBelow sides + 1 end

law `rolls are on the die` using seeded random 42 is
  definition is
    `for all` (sides :: Int64 where sides >= 1) . (let r = roll sides in r >= 1 && r <= sides) = true
  end
end

-- A session token: secure, so seeded random cannot stand in for it.
token :: Int32 -> Bytes uses SecureRandom
```

## Random

```lawspec fragment
ability Random is
  randomBelow :: Int64 -> Int64
end
```

`randomBelow n` draws from 0 up to, not including, `n`; it gives 0 when `n`
is not positive. Every handler keeps that law.

`Random` is a 64-bit linear congruential generator (Knuth's MMIX constants),
the same on every target, so the same seed gives the same draws on all eight:

- **`seeded random n`** in a law's `using` list starts it at `n`. It is the
  spec handler `seededRandom`, with the generator's state as its state, so
  the compiler can evaluate laws under it. In a definition, `handle e with
  seededRandom 42 end` (or `seeded random 42`) runs `e` under it started at
  42; without a seed it starts at 0.
- **The default handler** starts at the run's seed: `LAWSPEC_SEED`, or 0. A
  run repeated with the same seed draws the same values.

## SecureRandom

```lawspec fragment
ability SecureRandom is
  secureBytes :: Int32 -> Bytes
  secureBelow :: Int64 -> Int64
  secureToken :: Text
end
```

- `secureBytes n` is `n` bytes (none when `n` is negative); `secureBelow n`
  is a uniform draw from 0 up to `n`; `secureToken` is 32 bytes as 64
  lowercase hexadecimal digits.
- Its laws: the lengths, the bound, and that two draws of 32 bytes differ.
- **The default handler** is the operating system's generator: `secrets` in
  Python, `node:crypto` in JavaScript, `crypto/rand` in Go,
  `java.security.SecureRandom` on the JVM, crypton's system entropy in
  Haskell and `getrandom` in Rust.

## Why two abilities

Reproducible randomness and secure randomness are different promises. A
test wants the first: a failure found under seed 42 should happen again
under seed 42. A token, a key or a nonce wants the second: no one may
predict it, so it must not repeat under a seed. If one ability served both,
the handler a law installs to make a test reproducible would also answer the
code that makes keys, and a predictable key would pass every test.

So LawSpec keeps them apart, in the types:

- `seeded random n` handles `Random`, never `SecureRandom`. A law that names
  it while what it calls needs `SecureRandom` is a compile error: `the law
  ... needs SecureRandom, which a seeded Random cannot answer`. The same
  holds for `handle e with seededRandom end`.
- `SecureRandom` has no spec handlers: a handler written in LawSpec is
  deterministic, so `handler h for SecureRandom` is an error.
- Natively, `Random` and `SecureRandom` are distinct interfaces, so passing
  a seeded handler where a secure one is needed fails to compile in Go,
  Java, Kotlin, TypeScript, Haskell and Rust, and fails its laws in Python
  and JavaScript.

Laws about code that uses `SecureRandom` therefore hold for every secure
source: they cannot depend on which values it draws.
