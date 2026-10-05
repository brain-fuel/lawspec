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

// CheckStock takes 400ms for order -1; a negative order has no stock.
func CheckStock(value0 Order) LawSpecTask[LawSpecEither[string, Order]] {
	return LawSpecGo(func() LawSpecEither[string, Order] {
		if value0.Number == -1 {
			time.Sleep(400 * time.Millisecond)
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
			time.Sleep(250 * time.Millisecond)
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
