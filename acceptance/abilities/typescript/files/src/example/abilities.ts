// User-owned LawSpec adapter: a native Gateway handler and a native adapter
// that uses Gateway through the handler it is given.
import * as data from '.././lawspec_data.js';
import * as schema from '.././lawspec_schema.js';
import * as ls from '../lawspec_runtime.js';
import type * as abilities from '.././lawspec_abilities/example/abilities.js';
// LawSpec argument 0: Int32
// LawSpec result: Bool
export function charge(gateway: abilities.Gateway, value0: number): boolean {
  const payment = gateway.authorize(value0);
  if (payment instanceof data.PaymentApproved) {
    return gateway.capture(payment.cents).cents === value0;
  }
  return false;
}

/** The native handler of Gateway: authorize, capture, fee. */
export class GatewayHandler implements abilities.Gateway {
  authorize(value0: number): data.Payment {
    if (value0 < 0) return new data.PaymentDeclined();
    return new data.PaymentApproved(value0);
  }
  capture(value0: number): data.Receipt {
    return new data.Receipt(value0);
  }
  fee(): number {
    return 25;
  }
}
