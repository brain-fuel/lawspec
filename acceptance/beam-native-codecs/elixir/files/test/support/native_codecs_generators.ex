defmodule Native.CodecsGenerators do
  def parcels(child), do: StreamData.map(child, &%{private: &1})
  def positives(), do: StreamData.map(StreamData.integer(1..127), &%{positive: &1})
end
