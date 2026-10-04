# Lesson 1: Your first law

In this lesson you set up a project, write one law about a pair of functions,
let LawSpec generate the tests, and make them pass. By the end you will have
seen a law catch a bug.

We are building the ordering system of a small coffee shop. Quantities are
stored as numbers but shown to customers as text, so we need two functions:
one that formats a quantity and one that parses it back.

## Set up a project

LawSpec is an npm package. It needs Node 22 or later, whatever language you
test in.

::: only java
You also need JDK 25 and Maven. Create a directory, install LawSpec, and add a
Java project:

```sh
mkdir coffee-shop && cd coffee-shop
npm init -y
npm install --save-dev lawspec@0.18.0
npx lawspec init --target java --project java
npx lawspec doctor
```
:::

::: only python
You also need Python 3.13 or later. Create a directory, install LawSpec, and
add a Python project with its own virtual environment:

```sh
mkdir coffee-shop && cd coffee-shop
npm init -y
npm install --save-dev lawspec@0.18.0
npx lawspec init --target python --project python
python3 -m venv python/.venv
python/.venv/bin/python -m pip install -e "python[test]"
```

Point LawSpec at that interpreter: in `lawspec.json`, give the Python target
`"python": "python/.venv/bin/python"`. Then run `npx lawspec doctor`.
:::

::: only javascript
Create a directory, install LawSpec, and add a JavaScript project:

```sh
mkdir coffee-shop && cd coffee-shop
npm init -y
npm install --save-dev lawspec@0.18.0
npx lawspec init --target javascript --project javascript
npm install --prefix javascript
npx lawspec doctor
```
:::

`init` writes `lawspec.json`, a starter specification in `laws/`, and the
build files of the new project. `doctor` checks that your toolchain is ready.
Delete the starter specification: you will write your own.

## Write the specification

Save this as `laws/codec.lawspec`. Every example on this site is a workbench:
pick a language, and it shows the specification and your implementation, both
editable, next to the tests LawSpec generates, which you can read but not
change.

- **▶ Run** generates the tests from the specification as it is now and runs
  them against the implementation as it is now, in an isolated frame in your
  browser. JavaScript and TypeScript, grouped under **▶ Runs here**, run in the
  browser; TypeScript is transpiled first, without type checking. For the other
  languages the button names the command that runs them in your project.
- **Check** compiles the specification and shows how each law is established.
- **↺** restores the example.

Workbenches on a page share their files: the one under "Implement the
adapters" edits the same implementation that **▶ Run** tests here.

```lawspec file=docs/lessons/specs/01-first-law.lawspec implementations=acceptance/lessons
```

A LawSpec source is one **unit**, here `lessons.codec`. Its name decides where
generated code goes.

`formatQuantity` and `parseQuantity` are **adapters**: functions your code
provides. LawSpec knows only their types.

The **law** says what must be true of them. It reuses a law from the prelude,
`round trip identity is preserved`, which expands to: for every `Int32` value
`x`, `parseQuantity (formatQuantity x) = x`. The **example** pins one concrete
case, with the values it must produce.

## Generate the tests

```sh
npx lawspec generate
```

::: only java
LawSpec writes three kinds of files under `java/`:

- `src/main/java/lessons/Codec.java`, the adapter class. It is yours: LawSpec
  creates it once, with a stub for each adapter, and never overwrites it.
- `src/test/java/lessons/CodecLawSpecTest.java`, the tests. They are generated,
  and LawSpec replaces them whenever the specification changes.
- Support code in `lawspec/`, also generated.
:::

::: only python
LawSpec writes three kinds of files under `python/`:

- `src/lessons/codec.py`, the adapter module. It is yours: LawSpec creates it
  once, with a stub for each adapter, and never overwrites it.
- `tests/test_lessons_codec_lawspec.py`, the tests. They are generated, and
  LawSpec replaces them whenever the specification changes.
- Support modules such as `src/lawspec_runtime.py`, also generated.
:::

::: only javascript
LawSpec writes three kinds of files under `javascript/`:

- `src/lessons/codec.mjs`, the adapter module. It is yours: LawSpec creates it
  once, with a stub for each adapter, and never overwrites it.
- `test/lessons_codec.lawspec.test.mjs`, the tests. They are generated, and
  LawSpec replaces them whenever the specification changes.
- Support modules such as `src/lawspec_runtime.mjs`, also generated.
:::

## Implement the adapters

Replace the stubs:

::: only java
```lawspec file=docs/lessons/specs/01-first-law.lawspec implementations=acceptance/lessons view=implementation target=java
```
:::

::: only python
```lawspec file=docs/lessons/specs/01-first-law.lawspec implementations=acceptance/lessons view=implementation target=python
```
:::

::: only javascript
```lawspec file=docs/lessons/specs/01-first-law.lawspec implementations=acceptance/lessons view=implementation target=javascript
```
:::

## Run the tests

::: only java
```sh
cd java && mvn test
```
:::

::: only python
```sh
cd python && .venv/bin/python -m pytest
```
:::

::: only javascript
```sh
cd javascript && npm test
```

Or press **▶ Run** on the example above: the same generated tests run in your
browser, against the implementation shown there.
:::

The tests check the example, the edge values of `Int32` (the smallest, the
largest, zero and its neighbours), and a hundred generated values.

## Break it

Suppose the formatter drops the sign, formatting `-1` as `"1"`. That is easy
to miss by hand, because every example you think of is positive. The law is
about every `Int32`, so the tests try negative numbers too, and fail:

```text
lessons.codec::quantities survive a round trip boundary 1
  | expect parseQuantity (formatQuantity (_input0)) = _input0
  | actual=1 expected=-1
```

Each track reports the law, the case (here the second boundary value, `-1`)
and the values involved. A failing generated case is also shrunk to a small
counterexample.

## What you learned

- A unit declares adapters, which your code implements, and laws about them.
- `lawspec generate` writes tests you never edit, and adapter stubs you own.
- One law covers every input, including the ones you would not think of.

Next: [examples and expectations](02-examples.md).
