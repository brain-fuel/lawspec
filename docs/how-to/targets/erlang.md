---
id: lawspec.how-to.targets.erlang
kind: how-to
title: Erlang target
---
# Erlang target

Use Erlang/OTP 29, Rebar3 3.27.1 and PropEr 1.5.0. Generated properties use
PropEr's generators and shrinking, with EUnit as the native test runner.

## Build setup

`lawspec init --target erlang` creates an application under `src` and this
test configuration in `rebar.config`:

```erlang
{erl_opts, [debug_info]}.
{eunit_opts, [{print_depth, 100}, {report, {lawspec_beam_report, []}}]}.
{profiles, [{test, [{deps, [{proper, "1.5.0"}]}]}]}.
```

Prepare the test dependencies before generation:

```sh
rebar3 as test compile
npx lawspec doctor --target erlang
npx lawspec generate --target erlang
rebar3 eunit
```

Runtime and adapter modules go in `src`; property helpers and generated tests
go in `test`. With another `sourceDir`, include it in Rebar's `src_dirs`. With
another `testDir`, include it in `extra_src_dirs`.

## Adopt an existing application

Merge the PropEr dependency and EUnit reporter into the effective Rebar
`test` profile. The reporter preserves native test results and records which
LawSpec checks actually completed. Keep EUnit discovery unfiltered: doctor
rejects `eunit_tests` overrides and an `eunit` alias.

Doctor evaluates `rebar.config` and `rebar.config.script` through Rebar's own
configuration reader, checks the compiled PropEr application, and rejects a
local checkout replacement or stale compiled version. It does not run EUnit.

## Typed definitions and handlers

A checked definition whose values all have native forms runs typed: it is a
function in `lawspec_typed` over the same tuples, lists, binaries and
integers your code uses. Only `KeyVal` and `Set` values convert at its
boundary, since typed code keeps them as maps and version 2 `sets`.
Integers are checked where their type bounds them, and `Text` is UTF-8
measured in code points. Each function is named for its definition, with `_2` only when two
would share a name, so its name survives unrelated edits.

A spec handler whose clauses are all typed keeps its state in its cell's
process and runs each operation there, so an operation copies only its
arguments and result. `cluster_typed_state(Broker)` returns that state as
typed code holds it, and `cluster_set_typed_state(Broker, State)` replaces
it. Processes share no heap, so the snapshot is a copy. `lawspec-dev bench
kafka --typed` lists the definitions that stay dynamic, and why. See
[Embed a generated model](../embed-a-generated-model.md).

## Resource adapters

Resource acquisition and release run in a dedicated owner process; the test
worker borrows the handle. Route operations on private native state back to
that owner. See [BEAM ownership and cancellation](../../reference/language/resources.md#beam-ownership-and-cancellation)
for the callback contract, owner-call helper and cleanup deadlines.

## Native crypto bridge

Programs importing `lawspec.crypto` or `lawspec.network` use a small C NIF to
preserve LawSpec's shared seed key format. Use a Unix C compiler and OpenSSL
3.5 or later development headers and libraries. OpenSSL must have the same
major version as the library used by OTP, and OTP must expose the required
post-quantum algorithms.

The builder discovers OpenSSL through `pkg-config` or Homebrew. Set
`LAWSPEC_OPENSSL_PREFIX` to select another installation; `CC` names one compiler
executable. Paths containing spaces are supported.

```sh
escript lawspec_crypto_build.escript
```

For Rebar, add the compile hook (crypto scaffolds include it):

```erlang
{pre_hooks, [{compile, "escript lawspec_crypto_build.escript"}]}.
```

Build on macOS or Linux, or use WSL on Windows. Ship the compiled `priv`
directory with the application. The library is built for the deployment's
OS, architecture and OTP/OpenSSL installation; it is not a portable binary.
The application does not invoke a C compiler at startup.

Doctor builds and loads the same bridge in a temporary project, so missing
headers, unsupported algorithms or a library mismatch fail before generation.
Projects that do not use crypto need no C build step.

## Formatting

Output is what `erlfmt` 1.8.0 writes with its default settings: four-space
indentation and 100 columns, with operators breaking after themselves and
`case` expressions always on lines of their own. LawSpec lays it out itself,
so generation needs no formatter, and LawSpec's own acceptance checks every
generated project, runtime included, with `erlfmt --check`. `--minify`
allows a compact layout.

## Names

Generated Erlang uses the specification's names. Binders are Erlang
variables in PascalCase (`money` is `Money`); a checked definition is a
function of `lawspec_definitions` named after it in snake case (`feeModel`
is `fee_model`), with `_2` only when two would share a name, and abilities
and handlers have functions of `lawspec_abilities` named after them. Each
law's cases are functions named after the law and the case:
`law_normalizers_agree__spaces_become_hyphens_punctuation_is_preserved`,
`law_normalizers_agree__boundary_1` and `law_normalizers_agree__property`.
Each case and definition has a comment linking it to its source line, under
the law's comment, which gives what it says and the statement its tests
check. Text is written as binaries (`<<"café"/utf8>>`), integer arithmetic
and comparison as Erlang's operators, and an anonymous record from where it
is used: the payload of a `Declined` case is `declined_details`.
