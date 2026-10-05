# User-owned LawSpec adapter: a native Gateway handler and a native adapter
# that uses Gateway through the handler it is given.
import builtins as _builtins
import lawspec_data as data
import lawspec_schema as _schema
import lawspec_runtime as ls


# LawSpec argument 0: Int32
# LawSpec result: Bool
def charge(gateway: "lawspec_abilities.example.abilities.Gateway", value0: int) -> bool:
    payment = gateway.authorize(value0)
    if isinstance(payment, data.PaymentApproved):
        return gateway.capture(payment.cents).cents == value0
    return False


class GatewayHandler:
    """The native handler of Gateway: authorize, capture, fee."""

    def authorize(self, value0: _builtins.int) -> data.Payment:
        if value0 < 0:
            return data.PaymentDeclined()
        return data.PaymentApproved(value0)

    def capture(self, value0: _builtins.int) -> data.Receipt:
        return data.Receipt(value0)

    def fee(self) -> _builtins.int:
        return 25
