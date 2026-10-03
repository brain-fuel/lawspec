// User-owned LawSpec adapter.
package workflows

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
