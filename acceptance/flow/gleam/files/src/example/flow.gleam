// ref:DEC-acceptance-with-mutants
import lawspec/data

pub fn push(value: Int, stack: data.Stack) -> data.PushFlow {
  data.PushFlow(data.StackPush(data.PushDetails(stack, value)))
}
pub fn pop(stack: data.Stack) -> data.PopFlow {
  let assert data.StackPush(data.PushDetails(rest, top)) = stack
  data.PopFlow(top, rest)
}
pub fn peek(stack: data.Stack) -> data.PeekFlow {
  let assert data.StackPush(data.PushDetails(_, top)) = stack
  data.PeekFlow(top, stack)
}
