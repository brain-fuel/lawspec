// Application code: a Clock bound in lawspec.json in place of the default
// one. It keeps the default clock's readings. Each Go package has its own
// Clock, so each that uses one has this file.
package builtins

// SteadyClock passes its operations on to the default Clock.
type SteadyClock struct {
	inner    Clock
	readings int64
}

// NewSteadyClock makes the bound Clock.
func NewSteadyClock() Clock {
	return &SteadyClock{inner: NewClockHandler()}
}

func (clock *SteadyClock) Now() Instant {
	clock.readings++
	return clock.inner.Now()
}

func (clock *SteadyClock) Sleep(value0 LawSpecDuration) {
	clock.inner.Sleep(value0)
}
