# ref:DEC-tests-cite-requirements ref:DEC-stateful-models-linearizability
defmodule Example.Models do
  alias LawSpec.Data.{StackEmpty, StackPush, PushFlow, PopFlow, PeekFlow, Counter}

  def empty(:ok), do: %StackEmpty{}
  def push(n, s), do: %PushFlow{state: %StackPush{top: n, rest: s}}
  def pop(%StackPush{top: n, rest: s}), do: %PopFlow{result: n, state: s}
  def peek(%StackPush{top: n} = s), do: %PeekFlow{result: n, state: s}
  def new_counter(:ok), do: %Counter{id: :beam_model_counter.new()}
  def increment(%Counter{id: id}), do: :beam_model_counter.increment(id)
  def decrement(%Counter{id: id}), do: :beam_model_counter.decrement(id)
  def read(%Counter{id: id}), do: :beam_model_counter.read(id)
end
