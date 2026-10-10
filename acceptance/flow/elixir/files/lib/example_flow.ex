# ref:DEC-acceptance-with-mutants
defmodule Example.Flow do
  alias LawSpec.Data.{StackPush, PushFlow, PopFlow, PeekFlow}
  def push(value, stack), do: %PushFlow{state: %StackPush{top: value, rest: stack}}
  def pop(%StackPush{top: top, rest: rest}), do: %PopFlow{result: top, state: rest}
  def peek(%StackPush{top: top} = stack), do: %PeekFlow{result: top, state: stack}
end
