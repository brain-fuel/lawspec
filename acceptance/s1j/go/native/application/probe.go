package application

type Envelope struct{ Flag bool }
type Probe struct{}

func NewProbe() *Probe                      { return &Probe{} }
func (*Probe) Read(value Envelope) Envelope { return value }
