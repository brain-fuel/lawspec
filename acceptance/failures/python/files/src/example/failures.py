# User-owned LawSpec adapter: the native Gateway handler.
import builtins as _builtins
import lawspec_data as data
import lawspec_runtime as ls


class GatewayHandler:
    """The native handler of Gateway: decide."""

    def decide(self, value0: _builtins.int) -> data.Decision:
        if value0 < 0:
            return data.DecisionBlock()
        if value0 % 2 == 1:
            return data.DecisionDecline("an odd amount")
        return data.DecisionApprove()


# Native adapters that fail: they raise the runtime's Fail with a
# PaymentError, which a law expects with `fails with`.
# LawSpec argument 0: Int32
# LawSpec result: Int32
def refund(value0: int) -> int:
    if value0 > 5000:
        raise ls.Fail(data.PaymentErrorTooLarge(5000))
    return value0


# LawSpec argument 0: Int32
# LawSpec result: Int32
async def settle(value0: int) -> int:
    if value0 < 0:
        raise ls.Fail(data.PaymentErrorBlocked())
    if value0 == 0:
        raise ls.Fail(data.PaymentErrorDeclined("there is nothing to settle"))
    return value0
