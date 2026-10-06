# User-owned LawSpec adapter: the native Gateway handler.
import builtins as _builtins
import lawspec_data as data


class GatewayHandler:
    """The native handler of Gateway: decide."""

    def decide(self, value0: _builtins.int) -> data.Decision:
        if value0 < 0:
            return data.DecisionBlock()
        if value0 % 2 == 1:
            return data.DecisionDecline("an odd amount")
        return data.DecisionApprove()
