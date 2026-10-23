# ref:DEC-acceptance-with-mutants
defmodule Example.Flow do
  alias LawSpec.Data.{StackPush, PushFlow, PopFlow, PeekFlow}
  def push(value, stack), do: %PushFlow{state: %StackPush{value: %LawSpec.Data.PushDetails{top: value, rest: stack}}}
  def pop(%StackPush{value: %LawSpec.Data.PushDetails{top: top, rest: rest}}), do: %PopFlow{result: top, state: rest}
  def peek(%StackPush{value: %LawSpec.Data.PushDetails{top: top}} = stack), do: %PeekFlow{result: top, state: stack}
end
