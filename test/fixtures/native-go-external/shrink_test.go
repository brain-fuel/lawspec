package binding

import (
	"testing"

	"pgregory.net/rapid"
)

// This intentionally fails; the runner checks the reduced counterexample.
func TestExternalShrinking(t *testing.T) {
	schema := lawSpecDataSchemaRegistry()
	bits := 64
	symbols := map[string]*lawSpecSymbol{}
	child := lsScalarCodec[int8](schema, bits, "Int8")
	codec := lawSpecNativeBoxCodec(schema, bits, child, symbols)
	factory := lawSpecNativeFactories()["external.binding::type::Box"]
	values := factory(schema, lsNamed("external.binding::type::Box", lsNamed("Int8")), bits, symbols,
		[]*rapid.Generator[LawSpecValue]{lsNativeGeneratorValues(child, rapid.Int8Range(1, 100))})
	rapid.Check(t, func(t *rapid.T) {
		value := codec.toNative(values.Draw(t, "externalBox"))
		if value.Payload > 60 {
			t.Fatalf("payload %d", value.Payload)
		}
	})
}
