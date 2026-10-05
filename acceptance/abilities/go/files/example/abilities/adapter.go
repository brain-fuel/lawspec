// User-owned LawSpec adapter: a native Gateway handler and a native adapter
// that uses Gateway through the handler it is given.
package abilities

// Charge implements charge :: (Int32 -> Bool).
func Charge(gateway Gateway, value0 int32) bool {
	if approved, ok := gateway.Authorize(value0).(PaymentApproved); ok {
		return gateway.Capture(approved.Cents).Cents == value0
	}
	return false
}

// GatewayHandler is the native handler of Gateway: authorize, capture, fee.
type GatewayHandler struct{}

// NewGatewayHandler makes the native handler the generated tests use.
func NewGatewayHandler() Gateway {
	return &GatewayHandler{}
}

func (handler *GatewayHandler) Authorize(value0 int32) Payment {
	if value0 < 0 {
		return PaymentDeclined{}
	}
	return PaymentApproved{Cents: value0}
}

func (handler *GatewayHandler) Capture(value0 int32) Receipt {
	return Receipt{Cents: value0}
}

func (handler *GatewayHandler) Fee() int32 {
	return 25
}
