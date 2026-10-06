// User-owned LawSpec adapter: the native Gateway handler.
package failures

// GatewayHandler is the native handler of Gateway: decide.
type GatewayHandler struct{}

// NewGatewayHandler makes the native handler the generated tests use.
func NewGatewayHandler() Gateway {
	return &GatewayHandler{}
}

func (handler *GatewayHandler) Decide(value0 int32) Decision {
	if value0 < 0 {
		return DecisionBlock{}
	}
	if value0%2 == 1 {
		return DecisionDecline{Reason: "an odd amount"}
	}
	return DecisionApprove{}
}

// Native adapters that fail: they panic with the runtime's LawSpecFail and
// a PaymentError, which a law expects with `fails with`.

// Refund implements refund :: (Int32 -> Int32).
func Refund(value0 int32) int32 {
	if value0 > 5000 {
		panic(LawSpecFail{Value: PaymentErrorTooLarge{Limit: 5000}})
	}
	return value0
}

// Settle implements settle :: (Int32 -> Int32), asynchronously.
func Settle(value0 int32) LawSpecTask[int32] {
	return LawSpecGo(func() int32 {
		if value0 < 0 {
			panic(LawSpecFail{Value: PaymentErrorBlocked{}})
		}
		if value0 == 0 {
			panic(LawSpecFail{Value: PaymentErrorDeclined{Message: "there is nothing to settle"}})
		}
		return value0
	})
}
