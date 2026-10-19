# ref:DEC-acceptance-with-mutants
defmodule Example.Flow do
  alias LawSpec.Data.{StackPush, PushFlow, PopFlow, PeekFlow}
  def push(value, stack), do: %PushFlow{state: %StackPush{value: %LawSpec.Data.Record6e70c38da816203dd3a94111f83b422c58c2d67a01c3842a3fd23715879f00be{top: value, rest: stack}}}
  def pop(%StackPush{value: %LawSpec.Data.Record6e70c38da816203dd3a94111f83b422c58c2d67a01c3842a3fd23715879f00be{top: top, rest: rest}}), do: %PopFlow{result: top, state: rest}
  def peek(%StackPush{value: %LawSpec.Data.Record6e70c38da816203dd3a94111f83b422c58c2d67a01c3842a3fd23715879f00be{top: top}} = stack), do: %PeekFlow{result: top, state: stack}
end
