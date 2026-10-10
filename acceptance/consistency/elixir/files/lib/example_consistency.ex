# ref:DEC-tests-cite-requirements ref:DEC-stateful-models-linearizability
defmodule Example.Consistency do
  alias LawSpec.Data.Views
  def new_views(:ok), do: %Views{id: :beam_views.new()}
  def hit(%Views{id: id}), do: :beam_views.hit(id)
  def total(%Views{id: id}), do: :beam_views.total(id)
end
