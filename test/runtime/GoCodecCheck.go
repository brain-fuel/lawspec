package fixture

import (
	"math"
	"reflect"
	"strconv"
	"testing"
)

type foreignTree struct{}

func (foreignTree) lawSpecTree(int8) {}

func checkNativeScalar[T any](t *testing.T, bits int, name string, native T) {
	t.Helper()
	schema := lawSpecDataSchemaRegistry()
	codec := lawSpecTreeCodec(schema, bits, lsScalarCodec[T](schema, bits, name))
	logical := codec.fromNative(TreeLeaf[T]{Value: native})
	restored := codec.toNative(logical).(TreeLeaf[T]).Value
	if !reflect.DeepEqual(native, restored) {
		t.Fatalf("%s round trip: %v != %v", name, native, restored)
	}
	if !schema.equal(codec.typeRef, logical, codec.fromNative(TreeLeaf[T]{restored}), bits) {
		t.Fatalf("%s logical round trip", name)
	}
}

func TestNativeScalarCodecs(t *testing.T) {
	for _, bits := range []int{32, 64} {
		checkNativeScalar(t, bits, "Bool", true)
		checkNativeScalar(t, bits, "Int8", int8(127))
		checkNativeScalar(t, bits, "UInt64", ^uint64(0))
		checkNativeScalar(t, bits, "BigInt", lsInt("9007199254740993"))
		checkNativeScalar(t, bits, "BigUInt", lsInt("18446744073709551616"))
		checkNativeScalar(t, bits, "Decimal", lsDecimal("3", "-1").Data.(lawSpecDecimal))
		checkNativeScalar(t, bits, "Rational", lsRational("1", "2").Data.(*LawSpecRational))
		checkNativeScalar(t, bits, "Float32", float32(0.1))
		checkNativeScalar(t, bits, "Float64", math.Inf(1))
		checkNativeScalar(t, bits, "Complex64", complex64(1+2i))
		checkNativeScalar(t, bits, "Complex128", complex128(1-2i))
		checkNativeScalar(t, bits, "Char", rune(0x1f642))
		checkNativeScalar(t, bits, "CodePoint", rune(0xd800))
		checkNativeScalar(t, bits, "CodeUnit16", uint16(0xdfff))
		checkNativeScalar(t, bits, "Text", "🙂")
		checkNativeScalar(t, bits, "CodePointText", []rune{0xd800, 0x1f642})
		checkNativeScalar(t, bits, "Utf16Text", []uint16{0xd800, 0, 0xdc00})
		checkNativeScalar(t, bits, "Bytes", []byte{0, 128, 255})
		checkNativeScalar(t, bits, "Unit", LawSpecUnit{})
		checkNativeScalar(t, bits, "Null", LawSpecNull{})
		checkNativeScalar(t, bits, "Undefined", LawSpecUndefined{})
		checkNativeScalar(t, bits, "Symbol", &LawSpecSymbol{"description"})
		schema := lawSpecDataSchemaRegistry()
		codec := lawSpecTreeCodec(schema, bits, lsScalarCodec[float64](schema, bits, "Float64"))
		nan := codec.fromNative(TreeLeaf[float64]{math.NaN()})
		if !math.IsNaN(codec.toNative(nan).(TreeLeaf[float64]).Value) || schema.equal(codec.typeRef, nan, nan, bits) {
			t.Fatal("native NaN semantics lost")
		}
		expectSchemaPanic(t, "invalid Decimal", func() {
			lsScalarCodec[LawSpecDecimal](schema, bits, "Decimal").fromNative(LawSpecDecimal{})
		})
		expectSchemaPanic(t, "invalid Rational", func() {
			lsScalarCodec[*LawSpecRational](schema, bits, "Rational").fromNative(nil)
		})
		if bits == strconv.IntSize {
			checkNativeScalar(t, bits, "IntSize", int(1))
			lawSpecMachineCodec(schema, bits).fromNative(MachineMachineField{1})
		} else {
			expectSchemaPanic(t, "machineBits", func() {
				lsScalarCodec[int](schema, bits, "IntSize")
			})
			expectSchemaPanic(t, "machineBits", func() { lawSpecMachineCodec(schema, bits) })
		}
	}
}

func TestNativeCodecCopiesAndConstructors(t *testing.T) {
	for _, bits := range []int{32, 64} {
		schema := lawSpecDataSchemaRegistry()
		codec := lawSpecTreeCodec(schema, bits, lsScalarCodec[[]byte](schema, bits, "Bytes"))
		bytes := []byte{0, 255}
		children := []Tree[[]byte]{TreeLeaf[[]byte]{bytes}}
		logical := codec.fromNative(TreeBranch[[]byte]{children})
		bytes[0] = 99
		children[0] = TreeBranch[[]byte]{}
		native := codec.toNative(logical).(TreeBranch[[]byte])
		if native.Children[0].(TreeLeaf[[]byte]).Value[0] != 0 {
			t.Fatal("native-to-logical conversion aliased a byte slice")
		}
		native.Children[0].(TreeLeaf[[]byte]).Value[0] = 88
		if codec.toNative(logical).(TreeBranch[[]byte]).Children[0].(TreeLeaf[[]byte]).Value[0] != 0 {
			t.Fatal("logical-to-native conversion aliased a byte slice")
		}
		ints := lawSpecTreeCodec(schema, bits, lsScalarCodec[int8](schema, bits, "Int8"))
		for _, invalid := range []Tree[int8]{nil, (*TreeLeaf[int8])(nil), foreignTree{}} {
			expectSchemaPanic(t, "unexpected native constructor", func() { ints.fromNative(invalid) })
		}
		text := lawSpecTreeCodec(schema, bits, lsScalarCodec[string](schema, bits, "Text"))
		expectSchemaPanic(t, "ctor::Leaf.value", func() { text.fromNative(TreeLeaf[string]{"\xff"}) })
		presence := lawSpecPresenceCodec(schema, bits)
		x := presence.fromNative(PresenceStates{Nested: LawSpecNullable[LawSpecOptional[int8]]{Present: true}})
		y := presence.fromNative(PresenceStates{})
		if schema.equal(presence.typeRef, x, y, bits) {
			t.Fatal("presence bridge collapsed nested states")
		}
		pair := lawSpecPairCodec(schema, bits, lsScalarCodec[string](schema, bits, "Text"))
		value := pair.toNative(pair.fromNative(PairPair[string]{"🙂", ^uint64(0)})).(PairPair[string])
		if value.Second != ^uint64(0) {
			t.Fatal("UInt64 bridge lost precision")
		}
		chain := lawSpecChainCodec(schema, bits)
		chain.fromNative(chain.toNative(chain.fromNative(ChainNext{LawSpecJust[Chain](ChainStop{})})))
		mutual := lawSpecLeftSideCodec(schema, bits)
		mutual.fromNative(mutual.toNative(mutual.fromNative(LeftSideAcross{RightSideBack{}})))
		either := lsEitherCodec(schema, bits, ints, pair)
		expectSchemaPanic(t, "Either requires", func() {
			either.fromNative(LawSpecEither[Tree[int8], Pair[string]]{})
		})
	}
}

func TestCyclicNativeValuesAreRejected(t *testing.T) {
	schema := lawSpecDataSchemaRegistry()
	codec := lawSpecTreeCodec(schema, 64, lsScalarCodec[int8](schema, 64, "Int8"))
	children := make([]Tree[int8], 1)
	cycle := TreeBranch[int8]{children}
	children[0] = cycle
	expectSchemaPanic(t, "cyclic structural value", func() { codec.fromNative(cycle) })
	shared := TreeBranch[int8]{[]Tree[int8]{TreeLeaf[int8]{1}}}
	codec.fromNative(TreeBranch[int8]{[]Tree[int8]{shared, shared}})
	values := make([]LawSpecValue, 1)
	logical := LawSpecValue{codec.typeRef.key(), lawSpecData{"ctor::Branch", []LawSpecValue{
		{Type: "List Tree Int8", Data: values},
	}}}
	values[0] = logical
	expectSchemaPanic(t, "cyclic structural value", func() { codec.toNative(logical) })
}
