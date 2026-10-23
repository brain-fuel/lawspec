// User-owned LawSpec adapter.
package example

import lawspec.data.PeekFlow
import lawspec.data.PopFlow
import lawspec.data.PushFlow
import lawspec.data.Stack

object Flow {
    fun push(value0: Byte, value1: Stack): PushFlow = PushFlow(Stack.Push(lawspec.data.PushDetails(value1, value0)))

    // The flow signature guarantees a nonempty stack.
    fun pop(value0: Stack): PopFlow {
        val cell = value0 as Stack.Push
        return PopFlow(cell.value.top, cell.value.rest)
    }

    fun peek(value0: Stack): PeekFlow {
        val cell = value0 as Stack.Push
        return PeekFlow(cell.value.top, cell)
    }
}
