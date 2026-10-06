// User-owned LawSpec adapter: the native Gateway handler.
import * as data from '.././lawspec_data.mjs';

/** The native handler of Gateway: decide. */
export class GatewayHandler {
  decide(value0) {
    if (value0 < 0) return new data.DecisionBlock();
    if (value0 % 2 === 1) return new data.DecisionDecline('an odd amount');
    return new data.DecisionApprove();
  }
}
