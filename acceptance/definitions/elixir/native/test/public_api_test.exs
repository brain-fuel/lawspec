# ref:DEC-total-definitions ref:DEC-acceptance-with-mutants
defmodule PublicAPITest do
  use ExUnit.Case, async: true

  test "native callers cross the checked integer and contract boundary" do
    assert Example.RefinedDefinitions.Definitions.increment(126) == 127
    error = assert_raise ErlangError, fn -> Example.RefinedDefinitions.Definitions.increment(127) end
    assert {:lawspec, {_, {:contract_failed, "precondition"}}} = error.original
    error = assert_raise ErlangError, fn -> Example.RefinedDefinitions.Definitions.increment(128) end
    assert {:lawspec, {:integer_out_of_range, "Int8"}} = error.original
  end

  test "generated public data uses typed Elixir structs" do
    pair = %LawSpec.Data.Pair{first: 2, second: true}
    assert Example.DataTypes.Definitions.positive_pair(2) == pair
    assert Example.DataTypes.Definitions.reciprocal_first(pair) == :lawspec_beam_scalar.ratio(1, 2)
    error = assert_raise ErlangError, fn ->
      Example.DataTypes.Definitions.reciprocal_first(%LawSpec.Data.Pair{first: 0, second: true})
    end
    assert {:lawspec, {_, {:contract_failed, "precondition"}}} = error.original
  end

  test "checked Core guards still short circuit at the native entry point" do
    assert Example.TotalFunctions.Definitions.guarded_narrow(126)
    refute Example.TotalFunctions.Definitions.guarded_narrow(127)
  end
end
