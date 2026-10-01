// User-owned LawSpec adapter.
import * as data from '.././lawspec_data.mjs';

export function push(value0, value1) {
  return new data.PushFlow(new data.StackPush(value0, value1));
}

export function pop(value0) {
  return new data.PopFlow(value0.top, value0.rest);
}

export function peek(value0) {
  return new data.PeekFlow(value0.top, value0);
}
