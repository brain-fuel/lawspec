# ref:DEC-acceptance-with-mutants
defmodule Example.Durations do
  alias LawSpec.Data.Duration
  def remaining(%Duration{value: budget}, %Duration{value: spent}) do
    %Duration{value: max(budget - spent, 0)}
  end
end
