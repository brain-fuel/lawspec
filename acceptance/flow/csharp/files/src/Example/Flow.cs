// User-owned LawSpec adapter. ref:DEC-acceptance-with-mutants
namespace Example;

using System;
using LawSpec.Data;

public static class Flow
{
    public static PushFlow Push(sbyte value, Stack stack) => new PushFlow(Stack.NewPush(new LawSpec.Data.PushDetails(stack, value)));

    // The flow signature guarantees a nonempty stack.
    public static PopFlow Pop(Stack stack) =>
        stack is Stack.Push cell
            ? new PopFlow(cell.value.Top, cell.value.Rest)
            : throw new ArgumentException("an empty stack", nameof(stack));

    public static PeekFlow Peek(Stack stack) =>
        stack is Stack.Push cell
            ? new PeekFlow(cell.value.Top, stack)
            : throw new ArgumentException("an empty stack", nameof(stack));
}
