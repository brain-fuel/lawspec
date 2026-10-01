// User-owned LawSpec adapter.
import * as data from '.././lawspec_data.js';

export function push(value0: number, value1: data.Stack): data.PushFlow {
  return new data.PushFlow(new data.StackPush(value0, value1));
}

// The flow signature guarantees a nonempty stack.
export function pop(value0: data.Stack): data.PopFlow {
  const cell = value0 as data.StackPush;
  return new data.PopFlow(cell.top, cell.rest);
}

export function peek(value0: data.Stack): data.PeekFlow {
  const cell = value0 as data.StackPush;
  return new data.PeekFlow(cell.top, cell);
}
