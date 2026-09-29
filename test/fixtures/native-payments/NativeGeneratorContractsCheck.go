package payments

import (
	"math/big"
	"os"
	"testing"

	"pgregory.net/rapid"
)

func TestNativeMoneyShrink(t *testing.T) {
	if os.Getenv("LAWSPEC_NATIVE_SHRINK") == "" {
		t.Skip("deliberately failing property")
	}
	schema := lawSpecDataSchemaRegistry()
	generator := lsCheckedDataStrategyWithAttempts(schema, lsNamed("example.payments::type::Money"),
		64, 64, 10, nil, nil, _lawspecScalarGenerator, lawSpecNativeFactories())
	rapid.Check(t, func(t *rapid.T) {
		money := generator.Draw(t, "price").requireValue().Data.(lawSpecData)
		amount := lsRatio(money.fields[0])
		if amount.Cmp(big.NewRat(161, 100)) >= 0 {
			t.Fatalf("minimal_money=%s", amount.RatString())
		}
	})
}
