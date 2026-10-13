// User-owned LawSpec adapter.
package example

import lawspec.data.PeekFlow
import lawspec.data.PopFlow
import lawspec.data.PushFlow
import lawspec.data.Stack

@groovy.transform.CompileStatic
final class Flow {
  static PushFlow push(byte value0, Stack value1) {
    return new PushFlow(new Stack.Push(value0, value1))
  }

  // The flow signature guarantees a nonempty stack.
  static PopFlow pop(Stack value0) {
    var cell = (Stack.Push) value0
    return new PopFlow(cell.top(), cell.rest())
  }

  static PeekFlow peek(Stack value0) {
    var cell = (Stack.Push) value0
    return new PeekFlow(cell.top(), cell)
  }
}
