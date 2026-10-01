// User-owned LawSpec adapter.
package example;

import lawspec.data.PeekFlow;
import lawspec.data.PopFlow;
import lawspec.data.PushFlow;
import lawspec.data.Stack;

public final class Flow {
  public static PushFlow push(byte value0, Stack value1) {
    return new PushFlow(new Stack.Push(value0, value1));
  }

  // The flow signature guarantees a nonempty stack.
  public static PopFlow pop(Stack value0) {
    var cell = (Stack.Push) value0;
    return new PopFlow(cell.top(), cell.rest());
  }

  public static PeekFlow peek(Stack value0) {
    var cell = (Stack.Push) value0;
    return new PeekFlow(cell.top(), cell);
  }
}
