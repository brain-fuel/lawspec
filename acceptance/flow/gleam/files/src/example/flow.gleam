// ref:DEC-acceptance-with-mutants
import lawspec/data

pub fn push(value: Int, stack: data.Stack) -> data.PushFlow {
  data.PushFlow(data.StackPush(value, stack))
}
pub fn pop(stack: data.Stack) -> data.PopFlow {
  let assert data.StackPush(top, rest) = stack
  data.PopFlow(top, rest)
}
pub fn peek(stack: data.Stack) -> data.PeekFlow {
  let assert data.StackPush(top, _) = stack
  data.PeekFlow(top, stack)
}
