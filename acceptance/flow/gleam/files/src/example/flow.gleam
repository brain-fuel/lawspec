// ref:DEC-acceptance-with-mutants
import lawspec/data

pub fn push(value: Int, stack: data.Stack) -> data.PushFlow {
  data.PushFlow(data.StackPush(data.Record6e70c38da816203dd3a94111f83b422c58c2d67a01c3842a3fd23715879f00be(stack, value)))
}
pub fn pop(stack: data.Stack) -> data.PopFlow {
  let assert data.StackPush(data.Record6e70c38da816203dd3a94111f83b422c58c2d67a01c3842a3fd23715879f00be(rest, top)) = stack
  data.PopFlow(top, rest)
}
pub fn peek(stack: data.Stack) -> data.PeekFlow {
  let assert data.StackPush(data.Record6e70c38da816203dd3a94111f83b422c58c2d67a01c3842a3fd23715879f00be(_, top)) = stack
  data.PeekFlow(top, stack)
}
