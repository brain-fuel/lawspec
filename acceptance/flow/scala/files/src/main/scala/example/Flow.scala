// User-owned LawSpec adapter.
package example

import lawspec.data.{PeekFlow, PopFlow, PushFlow, Stack}

object Flow {
  // (Int8 -> (example.flow::type::Stack -> example.flow::type::PushFlow))
  def push(value0: scala.Byte, value1: lawspec.data.Stack): lawspec.data.PushFlow =
    PushFlow(Stack.Push(lawspec.data.Record6e70c38da816203dd3a94111f83b422c58c2d67a01c3842a3fd23715879f00be(value1, value0)))

  // The flow signature guarantees a nonempty stack.
  // (example.flow::type::Stack -> example.flow::type::PopFlow)
  def pop(value0: lawspec.data.Stack): lawspec.data.PopFlow = {
    val cell = value0.asInstanceOf[Stack.Push]
    PopFlow(cell.value.top, cell.value.rest)
  }

  // (example.flow::type::Stack -> example.flow::type::PeekFlow)
  def peek(value0: lawspec.data.Stack): lawspec.data.PeekFlow = {
    val cell = value0.asInstanceOf[Stack.Push]
    PeekFlow(cell.value.top, cell)
  }
}
