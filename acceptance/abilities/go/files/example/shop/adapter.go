// User-owned LawSpec adapter: native handlers for the shop's abilities, and
// a native adapter that fails through LawSpecFail. Go packages keep their
// own copies of types, so this package has its own Gateway handler.
package shop

// Refund implements refund :: (Int32 -> Int32).
func Refund(gateway Gateway, value0 int32) int32 {
	if value0 > 100000 {
		panic(LawSpecFail{Value: PaymentErrorTooLarge{}})
	}
	return gateway.Capture(value0).Cents
}

// JournalHandler is the native handler of Journal: note.
type JournalHandler struct{ lines []string }

// NewJournalHandler makes the native handler the generated tests use.
func NewJournalHandler() Journal {
	return &JournalHandler{}
}

func (handler *JournalHandler) Note(value0 string) {
	handler.lines = append(handler.lines, value0)
}

// StoreInt32Handler is the native handler of Store Int32: load, save.
type StoreInt32Handler struct{ value int32 }

// NewStoreInt32Handler makes the native handler the generated tests use.
func NewStoreInt32Handler() StoreInt32 {
	return &StoreInt32Handler{}
}

func (handler *StoreInt32Handler) Load() int32 {
	return handler.value
}

func (handler *StoreInt32Handler) Save(value0 int32) {
	handler.value = value0
}

// StoreTextHandler is the native handler of Store Text: load, save.
type StoreTextHandler struct{ value string }

// NewStoreTextHandler makes the native handler the generated tests use.
func NewStoreTextHandler() StoreText {
	return &StoreTextHandler{}
}

func (handler *StoreTextHandler) Load() string {
	return handler.value
}

func (handler *StoreTextHandler) Save(value0 string) {
	handler.value = value0
}

// MeterHandler is the native handler of Meter: reading.
type MeterHandler struct{}

// NewMeterHandler makes the native handler the generated tests use.
func NewMeterHandler() Meter {
	return &MeterHandler{}
}

func (handler *MeterHandler) Reading() int32 {
	return 3
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
