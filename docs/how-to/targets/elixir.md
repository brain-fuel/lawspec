---
id: lawspec.how-to.targets.elixir
kind: how-to
title: Elixir target
---
# Elixir target

Use Erlang/OTP 29, Elixir 1.20.x and StreamData 1.4.0. Generated properties
use StreamData and its shrinkers inside ExUnit tests.

## Build setup

`lawspec init --target elixir` creates a Mix project with Elixir source in
`lib`, shared Erlang runtime modules in `src`, tests in `test`, and helpers
in `test/support`. In `mix.exs`, enable both source languages and include
test helpers only in the test environment:

```elixir
def project do
  [app: :example, version: "0.1.0", elixir: "~> 1.20",
   erlc_paths: ["src"] ++ test_support(),
   elixirc_paths: ["lib"] ++ test_support(),
   deps: [{:stream_data, "== 1.4.0", only: :test}]]
end

defp test_support do
  if Mix.env() == :test, do: ["test/support"], else: []
end
```

Prepare dependencies, then generate:

```sh
mix deps.get
MIX_ENV=test mix deps.compile
npx lawspec doctor --target elixir
npx lawspec generate --target elixir
mix test
```

## Adopt an existing application

Merge the compiler paths and dependency into `mix.exs`. If you set a custom
`sourceDir`, both Erlang and Elixir generated sources use that directory.
For a custom `testDir`, update Mix's `test_paths` and both compilers' support
paths.

Use this setup in `test/test_helper.exs`, keeping any other application setup:

```elixir
case System.get_env("LAWSPEC_SEED") do
  nil -> ExUnit.start()
  seed -> ExUnit.start(seed: String.to_integer(seed))
end

if Code.ensure_loaded?(LawSpec.Beam.ExUnitFormatter) do
  ExUnit.configure(formatters: Enum.uniq(
    ExUnit.configuration()[:formatters] ++ [LawSpec.Beam.ExUnitFormatter]))
end

if Code.ensure_loaded?(:lawspec_beam_resources) do
  :lawspec_beam_resources.configure_suite(Process.whereis(ExUnit.Server))
  ExUnit.after_suite(fn _ -> :lawspec_beam_resources.stop_suite() end)
end
```

The formatter records actual ExUnit completions for CLI reports. Doctor reads
the effective test environment and evaluates the helper with autorun disabled;
it does not execute a suite. Keep `*_test.exs` discovery, without custom
test filters, dry runs, or aliases for the test and language
compiler tasks.

ExUnit's `max_failures` may be a positive integer or `:infinity`. After the
limit is reached, scheduled units stop starting queued cases. Cases already
running finish in their original processes, including their release callbacks,
subject to the existing per-case timeout. A failed or interrupted native run
does not create passing entries in the CLI result cache.

## Crypto projects

Follow the shared [C/OpenSSL setup](erlang.md#native-crypto-bridge). Add a Mix
compiler before the ordinary compilers; crypto scaffolds include this:

```elixir
defmodule Mix.Tasks.Compile.LawspecCrypto do
  use Mix.Task.Compiler
  def run(_args) do
    {output, status} = System.cmd("escript", ["lawspec_crypto_build.escript"],
      stderr_to_stdout: true)
    IO.write(output)
    if status != 0, do: Mix.raise("LawSpec crypto bridge compilation failed")
    {:ok, []}
  end
end
```

Set `compilers: [:lawspec_crypto] ++ Mix.compilers()` in `project/0`, add
`:crypto` to `extra_applications`, and ship the built `priv` directory.

## Resource adapters

Resource acquisition and release run in a dedicated owner process; the test
worker borrows the handle. Route operations on private native state back to
that owner. See [BEAM ownership and cancellation](../../reference/language/resources.md#beam-ownership-and-cancellation)
for the callback contract, owner-call helper and cleanup deadlines.
