// User-owned LawSpec adapter.
package workflows

import (
	"sync"
	"time"
)

// Audit records a new account.
func Audit(value0 Account) bool {
	return true
}

// Waitlist recovers from an unavailable name.
func Waitlist(value0 SignupError) LawSpecEither[SignupError, Account] {
	if _, ok := value0.(SignupErrorUnavailable); ok {
		return LawSpecRight[SignupError, Account](Account{Name: "waitlist", Age: 18, Level: 0})
	}
	return LawSpecLeft[SignupError, Account](value0)
}

// CheckName requires a name.
func CheckName(value0 Signup) LawSpecEither[SignupError, Signup] {
	if len(value0.Name) == 0 {
		return LawSpecLeft[SignupError, Signup](SignupErrorMissingName{})
	}
	return LawSpecRight[SignupError, Signup](value0)
}

// CheckAge requires an adult.
func CheckAge(value0 Signup) LawSpecEither[string, Signup] {
	if value0.Age < 18 {
		return LawSpecLeft[string, Signup]("too young")
	}
	return LawSpecRight[string, Signup](value0)
}

// OpenAccount opens an account unless the name is taken.
func OpenAccount(value0 Signup) LawSpecEither[SignupError, Account] {
	if value0.Name == "taken" {
		return LawSpecLeft[SignupError, Account](SignupErrorUnavailable{})
	}
	return LawSpecRight[SignupError, Account](Account{Name: value0.Name, Age: value0.Age, Level: 1})
}

// Each check records when it fails, so ApprovalErrors can tell completion
// order from declaration order.
var (
	finishedLock sync.Mutex
	finished     []string
)

func finish(message string) {
	finishedLock.Lock()
	defer finishedLock.Unlock()
	finished = append(finished, message)
}

// Order -1's slow checks record when they ran, so approvedQuickly can tell whether they ran at the same time.
// The list is never cleared, so tests running at once cannot erase each other's records.
var (
	spansLock sync.Mutex
	spans     [][2]time.Time
)

func span(start time.Time) {
	spansLock.Lock()
	defer spansLock.Unlock()
	spans = append(spans, [2]time.Time{start, time.Now()})
}

// Overlapped reports whether two slow checks that started at or after since
// overlapped in time.
func Overlapped(since time.Time) bool {
	spansLock.Lock()
	defer spansLock.Unlock()
	ran := [][2]time.Time{}
	for _, s := range spans {
		if !s[0].Before(since) {
			ran = append(ran, s)
		}
	}
	for i := range ran {
		for j := i + 1; j < len(ran); j++ {
			if ran[i][0].Before(ran[j][1]) && ran[j][0].Before(ran[i][1]) {
				return true
			}
		}
	}
	return false
}

// CheckStock takes 400ms for order -1; a negative order has no stock.
func CheckStock(value0 Order) LawSpecTask[LawSpecEither[string, Order]] {
	return LawSpecGo(func() LawSpecEither[string, Order] {
		if value0.Number == -1 {
			start := time.Now()
			time.Sleep(400 * time.Millisecond)
			span(start)
		}
		if value0.Number < 0 {
			finish("no stock")
			return LawSpecLeft[string, Order]("no stock")
		}
		return LawSpecRight[string, Order](value0)
	})
}

// CheckCredit takes 250ms for order -1; a negative order has no credit.
func CheckCredit(value0 Order) LawSpecTask[LawSpecEither[string, Order]] {
	return LawSpecGo(func() LawSpecEither[string, Order] {
		if value0.Number == -1 {
			start := time.Now()
			time.Sleep(250 * time.Millisecond)
			span(start)
		}
		if value0.Number < 0 {
			finish("no credit")
			return LawSpecLeft[string, Order]("no credit")
		}
		return LawSpecRight[string, Order](value0)
	})
}

// ResetFinished forgets the failed checks.
func ResetFinished() {
	finishedLock.Lock()
	defer finishedLock.Unlock()
	finished = nil
}

// Finished is the failed checks' messages, in the order they finished.
func Finished() []string {
	finishedLock.Lock()
	defer finishedLock.Unlock()
	return append([]string{}, finished...)
}
