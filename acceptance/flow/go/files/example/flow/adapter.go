// User-owned LawSpec adapter.
package flow

// Push puts a value on top of the stack.
func Push(value0 int8, value1 Stack) PushFlow {
	return PushFlow{State: StackPush{Value: PushDetails{Rest: value1, Top: value0}}}
}

// Pop takes the top value; the flow signature guarantees one.
func Pop(value0 Stack) PopFlow {
	cell := value0.(StackPush)
	return PopFlow{Result: cell.Value.Top, State: cell.Value.Rest}
}

// Peek reads the top value and keeps the stack.
func Peek(value0 Stack) PeekFlow {
	cell := value0.(StackPush)
	return PeekFlow{Result: cell.Value.Top, State: cell}
}
