// User-owned LawSpec adapter: the native Gateway handler.
import * as data from '.././lawspec_data.js';
import type * as abilities from '.././lawspec_abilities/example/failures.js';

/** The native handler of Gateway: decide. */
export class GatewayHandler implements abilities.Gateway {
  decide(value0: number): data.Decision {
    if (value0 < 0) return new data.DecisionBlock();
    if (value0 % 2 === 1) return new data.DecisionDecline('an odd amount');
    return new data.DecisionApprove();
  }
}
