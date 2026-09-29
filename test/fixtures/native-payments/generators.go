package payments

import (
	"math/big"

	"pgregory.net/rapid"
)

func NativePrices() *rapid.Generator[Price] {
	return rapid.Map(rapid.IntRange(100, 200), func(cents int) Price {
		return Price{LawSpecDecimal{big.NewInt(int64(cents)), -2}, Euros}
	})
}
