---
id: lawspec
kind: index
title: LawSpec documentation
---
# LawSpec documentation

**State the law once. Check it everywhere.**

LawSpec is a specification language for the laws your code must obey. You write
function signatures, reusable laws and concrete examples once. The compiler
checks them and turns them into native property-based tests and implementation
adapters for Java, Python, JavaScript, TypeScript, Go, Haskell, Kotlin and Rust.
Each target uses its usual test framework, generators and shrinkers.

The compiler is written in Haskell. It ships in the `lawspec` npm package as
prebuilt WebAssembly, with a Node command-line interface and a typed JavaScript
API. You do not need a Haskell toolchain to use it.

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
```

## How the documentation is organized

The documentation has four sections. Each one serves a different purpose.

- **[Tutorials](tutorials/index.md)** are lessons. They take you from an empty
  directory to a working, tested project in one target language.
- **[How-to guides](how-to/index.md)** are recipes for specific tasks: configuring
  an existing project, generating tests in CI, binding your own domain types,
  and setting up each target.
- **[Reference](reference/index.md)** describes the language, the prelude, the
  scalar catalog, the CLI, `lawspec.json` and the compiler API.
- **[Explanation](explanation/index.md)** covers the ideas behind the design:
  why laws should be executable, how the compiler works, how evidence is
  reported and how generated files are owned.

## Where to start

- To try LawSpec, [install it and create a starter project](how-to/install-and-init.md).
- To add LawSpec to a codebase you already have, read
  [Configure an existing project](how-to/configure-an-existing-project.md) and
  the guide for your [target](how-to/targets/index.md).
- To learn the language, start with [syntax](reference/language/syntax.md) and
  [laws and examples](reference/language/laws-and-examples.md).
- To find out what a result such as `PROPERTY TESTED` means, read
  [evidence and discharge](explanation/evidence-and-discharge.md).

Release history is in the [changelog](../CHANGELOG.md).
