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
