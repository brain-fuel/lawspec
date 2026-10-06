// User-owned LawSpec adapter: the native Gateway handler.
import * as data from '.././lawspec_data.js';
import * as ls from '../lawspec_runtime.js';
import type * as abilities from '.././lawspec_abilities/example/failures.js';

/** The native handler of Gateway: decide. */
export class GatewayHandler implements abilities.Gateway {
  decide(value0: number): data.Decision {
    if (value0 < 0) return new data.DecisionBlock();
    if (value0 % 2 === 1) return new data.DecisionDecline('an odd amount');
    return new data.DecisionApprove();
  }
}

// Native adapters that fail: they throw the runtime's Fail with a
// PaymentError, which a law expects with `fails with`.
export function refund(value0: number): number {
  if (value0 > 5000) throw new ls.Fail(new data.PaymentErrorTooLarge(5000));
  return value0;
}

export async function settle(value0: number): Promise<number> {
  if (value0 < 0) throw new ls.Fail(new data.PaymentErrorBlocked());
  if (value0 === 0) throw new ls.Fail(new data.PaymentErrorDeclined('there is nothing to settle'));
  return value0;
}
