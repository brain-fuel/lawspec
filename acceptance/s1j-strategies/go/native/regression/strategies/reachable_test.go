package strategies

import (
	"testing"

	"pgregory.net/rapid"
)

func TestReachableConstructorContracts(t *testing.T) {
	schema := lawSpecDataSchemaRegistry()
	plain := lsNamed("regression.strategies::type::Plain")
	positive := lsNamed("regression.strategies::type::Positive")
	if schema.hasContractsFor(plain) || !schema.hasContractsFor(positive) {
		t.Fatal("contracts must follow the requested type's reachable fields")
	}
	rapid.Check(t, func(t *rapid.T) {
		_ = lsDataStrategy(schema, plain, 64, 64, _lawspecScalarGenerator).Draw(t, "plain")
	})
}
