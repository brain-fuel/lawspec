package payments

import "math/big"

// Application-owned domain types, separate from generated canonical types.
type CurrencyCode int

const (
	Dollars CurrencyCode = iota
	Euros
	Pounds
)

type Price struct {
	Major LawSpecDecimal
	Unit  CurrencyCode
}

type PaymentStatus interface{ payment() }
type Settled struct{ Price Price }
type Rejected struct{ Explanation string }

func (Settled) payment()  {}
func (Rejected) payment() {}

// AddFee uses independent exact integer arithmetic, without ambient rounding.
func AddFee(price Price) Price {
	exponent := min(price.Major.exponent, -1)
	power := func(n int) *big.Int {
		return new(big.Int).Exp(big.NewInt(10), big.NewInt(int64(n)), nil)
	}
	amount := new(big.Int).Mul(price.Major.coefficient, power(price.Major.exponent-exponent))
	fee := new(big.Int).Mul(big.NewInt(2), power(-1-exponent))
	return Price{LawSpecDecimal{new(big.Int).Add(amount, fee), exponent}, price.Unit}
}

func Restore(value PaymentStatus) PaymentStatus                                { return value }
func Store(values []LawSpecMaybe[PaymentStatus]) []LawSpecMaybe[PaymentStatus] { return values }
