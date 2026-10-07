---
id: lawspec.tutorials.index
kind: tutorial
title: Tutorials
---
# Tutorials

The lessons teach LawSpec by building the ordering system of a small coffee
shop, one idea at a time. Each lesson has a specification you can edit and
compile on the page, and an implementation in your language whose generated
tests pass.

Choose a track. The specifications are the same in every track; the setup,
the implementations and the commands are those of your language.

- [Java](java/01-first-law.md): JDK 25, Maven, JUnit and JetCheck.
- [Python](python/01-first-law.md): Python 3.13, pytest and Hypothesis.
- [JavaScript](javascript/01-first-law.md): Node 22, `node:test` and
  fast-check. The JavaScript tests also run in your browser.

| Lesson | You learn |
| --- | --- |
| 1. Your first law | adapters, laws, generated tests and a failing mutant |
| 2. Examples and expectations | `implies`, examples and `lawspec explain` |
| 3. Algebraic laws | prelude laws such as `commutative` and `identity` |
| 4. Structural data and definitions | sum and product types, checked definitions |
| 5. Refinements and contracts | refined types, generation inside them, contracts |
| 6. Domain modelling | wrappers and workflows |
| 7. Sharing laws between units | imports, generic laws and packages |
| 8. Evidence and keeping tests current | `lawspec evidence` and `generate --check` |

The lessons assume you can program in your chosen language. They do not assume
you have used property-based testing before.
