// User-owned LawSpec adapter: an account's handlers, run inside an actor.
package actors

import "sync"

// OpenAccount makes an empty account.
func OpenAccount(value0 LawSpecValue) Account {
	return Account{Balance: 0}
}

// Deposit adds the amount and replies with the new balance.
func Deposit(value0 Account, value1 uint8) Pair[int64, Account] {
	after := value0.Balance + int64(value1)
	return Pair[int64, Account]{First: after, Second: Account{Balance: after}}
}

// WithdrawAll empties the account and replies with what it held.
func WithdrawAll(value0 Account) Pair[int64, Account] {
	return Pair[int64, Account]{First: value0.Balance, Second: Account{Balance: 0}}
}

// Balance replies with the balance.
func Balance(value0 Account) Pair[int64, Account] {
	return Pair[int64, Account]{First: value0.Balance, Second: value0}
}

// Close empties the account.
func Close(value0 Account) Account {
	return Account{Balance: 0}
}

// DepositTwice starts an account actor and deposits from two goroutines.
func DepositTwice(value0 uint8) int64 {
	account := StartAccountActor()
	defer account.Stop()
	var callers sync.WaitGroup
	for range 2 {
		callers.Add(1)
		go func() {
			defer callers.Done()
			if _, err := account.Deposit(value0); err != nil {
				panic(err)
			}
		}()
	}
	callers.Wait()
	total, err := account.Balance()
	if err != nil {
		panic(err)
	}
	return total
}

// Reopen restarts a crashed account with the balance it had.
func Reopen(value0 Account) Account {
	return Account{Balance: value0.Balance}
}

// SurvivesCrash starts the bank, deposits, crashes the account and reads its
// balance through the same handle.
func SurvivesCrash(value0 uint8) int64 {
	bank := StartBankSupervisor()
	defer bank.Stop()
	if _, err := bank.Account.Deposit(value0); err != nil {
		panic(err)
	}
	if err := bank.Account.Crash(); err != nil {
		panic(err)
	}
	total, err := bank.Account.Balance()
	if err != nil {
		panic(err)
	}
	return total
}
