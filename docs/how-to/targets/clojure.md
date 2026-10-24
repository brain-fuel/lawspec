---
id: lawspec.how-to.targets.clojure
kind: how-to
title: Set up Clojure
---
# Set up Clojure

Clojure runs over the Java model. The program's data types, codecs, ability
interfaces, checked definitions, actors, sessions, mailboxes and network are
the [Java target's](java.md), compiled into `target/classes`. What you write
is Clojure: each unit's adapters are functions of a namespace, and the values
they take and give are Clojure data. Each unit's laws are `clojure.test` tests
whose properties run on test.check.

## Requirements

- JDK 25 and the Clojure CLI 1.12.
- Clojure 1.12.5 and, for tests, test.check 1.1.3.
- Bouncy Castle `bcprov-jdk18on` 1.86, only for programs that import
  `lawspec.crypto` or `lawspec.network`.

## Create the project

```sh
npx lawspec init --target clojure
npx lawspec doctor
npx lawspec generate
clojure -M:test
```

`init` creates `deps.edn`. Its `:test` alias runs `lawspec.test-runner`, which
compiles the Java model when it changed, runs every test namespace, and writes
JUnit XML to `target/test-results`. `clojure -M:build` compiles the model
alone, for a REPL or an application.

## Layout

| Files | Directory |
| --- | --- |
| Adapters (yours): one namespace per unit, such as `example/parse_port.clj` | `src` |
| Application code bound in `lawspec.edn` | anywhere in `src` |
| LawSpec's Clojure runtime: `lawspec.clojure`, `lawspec.build` | `src/lawspec` |
| The Java model, and a bridge class per unit that calls your namespace | `java/src` |
| Tests, such as `example/parse_port_lawspec_test.clj` | `test` |
| The law cases and test.check support the tests call | `java/test` |

`sourceDir` and `testDir` move `src` and `test`; the Java model stays in
`java/`.

## Adapters

Unit `example.parse_port` is namespace `example.parse-port`, with a function
per adapter, named in kebab case: `validPort` is `valid-port`. A name that
`clojure.core` has is excluded from the namespace (`:refer-clojure :exclude`),
and one that is a special form, such as `quote`, keeps a leading underscore.

```clojure
(ns example.parse-port)

(defn valid-port [x] (<= 1 x 65535))
(defn render [x] (if (valid-port x) (str x) (throw (IllegalArgumentException. "invalid port"))))
(defn parse [text] (Integer/parseInt text))
```

An asynchronous adapter returns a future, a promise or a `CompletableFuture`.
A native handler is a function that returns a map of the ability's
operations; keep state in an atom it closes over:

```clojure
(defn store-int32-handler []
  (let [value (atom 0)]
    {:load (fn [] @value)
     :save (fn [x] (reset! value x) nil)}))
```

An adapter that uses an ability gets the handler as its first argument, and
calls an operation with `lawspec.clojure/op`: `(ls/op gateway :capture 500)`.

## Data

Values cross the boundary as Clojure data:

| LawSpec | Clojure |
| --- | --- |
| A data type's value | A map: `{:lawspec/tag :payment/approved, :cents 500}` |
| A constructor without fields | Its tag alone: `:payment/declined` |
| `List a` | A vector |
| `Set a`, `KeyVal k v` | A set, a map |
| Integers | Longs, or bigints beyond them |
| `Decimal` | `BigDecimal` |
| `Maybe a` | `nil` or the value |
| `Either e a` | `[:left e]` or `[:right a]` |
| `Unit` | `nil` |
| Text, bytes, durations | `String`, `byte[]`, `java.time.Duration` |

A tag's namespace is the type's name and its name the constructor's, both in
kebab case, an acronym one word: `:currency/usd`. The names are the Java model's, so when two units declare a type
of one name, their tags carry the units' names: `:shop-orders-currency/gbp`.
Fields are kebab-case keys. A multimethod on `lawspec.clojure/tag` matches a
sum:

```clojure
(defmulti evaluate ls/tag)
(defmethod evaluate :expr/number [{:keys [value]}] value)
(defmethod evaluate :expr/plus [{:keys [left right]}] (+' (evaluate left) (evaluate right)))
```

## Failures

An adapter that `fails with E` fails with `lawspec.clojure/fail`, an ex-info
whose data holds `:lawspec/failure`:

```clojure
(when (> amount 5000) (ls/fail {:lawspec/tag :payment-error/too-large :limit 5000}))
```

## Native bindings

`lawspec.edn` binds functions, constructors, methods, handlers and failures
to Clojure. A name is a namespace's segments and a function, with
underscores for hyphens: `["till", "payments", "native_till"]` is
`till.payments/native-till`.

- A bound function is called in place of the adapter.
- A constructor makes a handle, any Clojure value; a method binding calls the
  function of that name in the constructor's namespace, with the handle first.
- A bound handler is a function returning a map of operations, used as the
  ability's production handler.
- A bound failure names an ex-info's `:type`: `["till", "card_declined"]`
  turns `(ex-info "declined" {:type :till/card-declined})` into the failure.
- A bound generator is a function of no arguments returning a test.check
  generator of the type's tagged values.

Clojure binds no types: a Clojure program uses the model's data.

## Checked definitions and the model

`lawspec.clojure/definition` makes a checked definition a Clojure function of
Clojure data; its first argument is the Symbol context:

```clojure
(def size (ls/definition lawspec.definitions.example.Total "size"))
(size {} [1 2])
```

Spec handlers, actors, sessions, mailboxes and the network are the
[Java classes](java.md), used from Clojure by interop; `ls/->clojure` turns a
value of the model into Clojure data.

## Tests

Each unit's laws are a `clojure.test` namespace, a test per case, named after
the law, a double dash and the kind of test: `integer-promotion--example-0`,
`integer-promotion--property`. Properties run on test.check with LawSpec's
generators: each generated case is a rose tree whose children are the smaller
cases the generator can make again, so shrinking never leaves a refinement.
`LAWSPEC_SEED` repeats a run.

A namespace's `test-ns-hook` runs its tests by the harness's schedule:
`order random` shuffles them by the run's seed, and `parallel` runs them at
once. A skipped law's test reports why it is skipped; retries, timeouts,
cover, targeted search, the failure database and benchmarks run in the
harness runtime.

`npx lawspec test` selects the tests of the laws an edit can affect with the
runner's `--select namespace/prefix`.
