// User-owned LawSpec adapter. ref:DEC-acceptance-with-mutants
namespace Example;

using System;
using LawSpec.Data;

public static class Flow
{
    public static PushFlow Push(sbyte value, Stack stack) => new PushFlow(Stack.NewPush(new LawSpec.Data.Record6e70c38da816203dd3a94111f83b422c58c2d67a01c3842a3fd23715879f00be(stack, value)));

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
