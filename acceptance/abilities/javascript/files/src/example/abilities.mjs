// User-owned LawSpec adapter: a native Gateway handler and a native adapter
// that uses Gateway through the handler it is given.
import * as data from '.././lawspec_data.mjs';
import * as schema from '.././lawspec_schema.mjs';
import * as ls from '../lawspec_runtime.mjs';
// LawSpec argument 0: Int32
// LawSpec result: Bool
export function charge(gateway, value0) {
  const payment = gateway.authorize(value0);
  if (payment instanceof data.PaymentApproved) {
    return gateway.capture(payment.cents).cents === value0;
  }
  return false;
}

/** The native handler of Gateway: authorize, capture, fee. */
export class GatewayHandler {
  authorize(value0) {
    if (value0 < 0) return new data.PaymentDeclined();
    return new data.PaymentApproved(value0);
  }
  capture(value0) {
    return new data.Receipt(value0);
  }
  fee() {
    return 25;
  }
}
