# ref:DEC-tests-cite-requirements ref:DEC-native-property-frameworks
ExUnit.start()

defmodule LawSpecStreamDataTest do
  use ExUnit.Case, async: false
  alias LawSpec.Beam.StreamData, as: G

  test "indexed families and existential witnesses use native generators" do
    assert :ok == :lawspec_beam_index_tests.run(G)
  end

  defp schema, do: :lawspec_beam_schema.new([], ["Int8", "Text", "Symbol"], 64)
  defp int(lo, hi), do: G.generator({"Int8", []}, schema(), make_ref(), [{">=", lo}, {"<=", hi}], [])
  defp check(generator, predicate, options \\ []) do
    StreamData.check_all(generator, [initial_seed: {42, 53, 64}, max_runs: 100, max_shrinking_steps: 1000] ++ options,
      fn value -> if predicate.(value), do: {:ok, value}, else: {:error, value} end)
  end

  test "bounded integers keep native shrink trees and the original domain" do
    assert {:error, %{shrunk_failure: 5}} = check(int(5, 127), fn _ -> false end)
  end

  test "dependent values and shrinks retain their predicates" do
    generator = G.bind(int(0, 5), fn x -> G.bind(int(x + 1, 6), fn y -> [x, y] end) end) |> G.complete()
    assert {:error, %{shrunk_failure: [0, 1]}} = check(generator, fn [x, y] ->
      assert y > x
      false
    end)
  end

  test "an empty dependent range redraws its prefix" do
    generator = G.bind(G.oneof([G.exactly(127), G.exactly(126)]), fn x ->
      G.bind(int(x + 1, 127), fn y -> [x, y] end)
    end) |> G.complete()
    assert {:ok, _} = check(generator, &(&1 == [126, 127]))
  end

  test "a dependent predicate redraws its prefix" do
    generator = G.bind(G.oneof([G.exactly(127), G.exactly(126)]), fn x ->
      G.bind(G.refine_input(G.exactly(127), &(&1 > x)), fn y -> [x, y] end)
    end) |> G.complete()
    assert {:ok, _} = check(generator, &(&1 == [126, 127]))
  end

  test "an impossible domain fails instead of passing without examples" do
    generator = int(5, 127) |> G.refine_input(fn _ -> false end) |> G.complete()
    assert_raise StreamData.FilterTooNarrowError, fn -> check(generator, fn _ -> true end) end
  end

  test "generated symbols never alias a literal in the same context" do
    symbols = make_ref()
    generator = G.generator({"Symbol", []}, schema(), symbols, [], [])
    literal = :lawspec_beam_scalar.literal(%{"type" => "Symbol", "id" => "0", "description" => "0"}, symbols)
    assert {:ok, _} = check(generator, fn value -> not :lawspec_beam_scalar.equal(value, literal) end)
  end

  # ref:DEC-structural-size-budget
  test "recursive values obey their structural node budget" do
    tree = {"Tree", []}
    schema = :lawspec_beam_schema.new([%{name: "Tree", parameters: 0, constructors: [
      %{tag: "Tree::Leaf", native_tag: :leaf, fields: [{"value", {"Int8", []}}]},
      %{tag: "Tree::Fork", native_tag: :fork, fields: [{"left", tree}, {"right", tree}]}
    ]}], ["Int8"], 64)
    generator = G.generator(tree, schema, make_ref(), [], []) |> StreamData.resize(32)
    assert {:ok, _} = check(generator, fn value ->
      assert :lawspec_beam_schema.validate(value, tree, schema) == value
      nodes(value) <= 33
    end)
  end

  test "a witness beyond the default structural limit supplies its minimum budget" do
    names = Enum.map(1..65, &Integer.to_string/1)
    declarations = Enum.zip(names, tl(names) ++ ["Int8"]) |> Enum.map(fn {name, child} ->
      %{name: name, parameters: 0, constructors: [%{tag: name, native_tag: :box, fields: [{"value", {child, []}}]}]}
    end)
    schema = :lawspec_beam_schema.new(declarations, ["Int8"], 64)
    witness = List.foldr(names, 0, fn name, value -> {:ls_data, name, [value]} end)
    type = {hd(names), []}
    generator = G.generator(type, schema, make_ref(), [], [witness])
    assert :ok == G.check("deep data", G.forall(generator, fn value ->
      :lawspec_beam_schema.validate(value, type, schema) == value
    end), numtests: 10, constraint_tries: 100, max_shrinks: 100)
  end

  test "zero shrink budget evaluates only the initial failing input" do
    Process.put(:callback_count, 0)
    assert_raise ErlangError, fn ->
      G.check("no shrinking", G.forall(int(5, 127), fn _ ->
        Process.put(:callback_count, Process.get(:callback_count) + 1)
        false
      end), numtests: 100, constraint_tries: 100, max_shrinks: 0)
    end
    assert Process.delete(:callback_count) == 1
  end

  defp nodes({:ls_data, _, values}), do: 1 + Enum.sum(Enum.map(values, &nodes/1))
  defp nodes(_), do: 1

  test "shrunk native exceptions and the requested seed survive reporting" do
    previous = System.get_env("LAWSPEC_SEED")
    System.put_env("LAWSPEC_SEED", "12345")
    try do
      error = assert_raise ErlangError, fn ->
        G.check("broken", G.forall(int(5, 127), fn n -> :erlang.error({:bad_adapter, n}) end),
          numtests: 100, max_shrinks: 1000, constraint_tries: 100)
      end
      assert {:lawspec, {:property_failed, "broken", {:seed, 12345}, failure}} = error.original
      assert {:counterexample, 5, :error, {:bad_adapter, 5}, _} = failure.shrunk_failure
      assert Process.get({G, :attempts}) == nil
      assert Process.get({:lawspec_beam_generators, :minimum}) == nil
    after
      if previous == nil, do: System.delete_env("LAWSPEC_SEED"), else: System.put_env("LAWSPEC_SEED", previous)
    end
  end
end
