package codecs

import (
	"testing"

	"pgregory.net/rapid"
)

// This intentionally fails; the runner checks the reduced counterexample.
func TestCodecShrinking(t *testing.T) {
	schema := lawSpecDataSchemaRegistry()
	bits := 64
	symbols := map[string]*lawSpecSymbol{}
	child := lsScalarCodec[int8](schema, bits, "Int8")
	codec := lawSpecNativeParcelCodec(schema, bits, child, symbols)
	factory := lawSpecNativeFactories()["native.codecs::type::Parcel"]
	values := factory(schema, lsNamed("native.codecs::type::Parcel", lsNamed("Int8")), bits, symbols,
		[]*rapid.Generator[LawSpecValue]{lsNativeGeneratorValues(child, rapid.Int8Range(1, 100))})
	rapid.Check(t, func(t *rapid.T) {
		value := codec.toNative(values.Draw(t, "parcel"))
		if value.Unpack() > 60 {
			t.Fatalf("payload %d", value.Unpack())
		}
	})
}
