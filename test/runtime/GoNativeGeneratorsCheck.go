package fixture

import (
	"fmt"
	"math/big"
	"os"
	"strings"
	"testing"

	"pgregory.net/rapid"
)

type nativeBox struct{ value int }

func nativeGeneratorFixture(bits int) (*lawSpecSchema, lawSpecCodec[int], lawSpecCodec[nativeBox]) {
	schema := lsNewSchema([]lawSpecDataSchema{
		{"Box", 1, []lawSpecConstructorSchema{{"Box", []lawSpecFieldSchema{{"item", lsParameter(0)}}}}},
	}, []string{"Int8"})
	integer := lsCodec(schema, bits, lsNamed("Int8"),
		func(value LawSpecValue) int { return int(value.Data.(*big.Int).Int64()) },
		func(value int, _ lawSpecPath) LawSpecValue { return lsInteger("Int8", fmt.Sprint(value)) })
	boxType := lsNamed("Box", lsNamed("Int8"))
	box := lsCodec(schema, bits, boxType,
		func(value LawSpecValue) nativeBox {
			return nativeBox{integer.toNative(value.Data.(lawSpecData).fields[0])}
		},
		func(value nativeBox, path lawSpecPath) LawSpecValue {
			return schema.construct(boxType, "Box", []LawSpecValue{integer.encode(value.value, path)}, bits)
		})
	return schema, integer, box
}

func TestNativeGenerators(t *testing.T) {
	for _, bits := range []int{32, 64} {
		schema, integer, box := nativeGeneratorFixture(bits)
		factories := map[string]lawSpecNativeFactory{
			"Int8": func(*lawSpecSchema, lawSpecTypeRef, int, map[string]*lawSpecSymbol, []*rapid.Generator[LawSpecValue]) *rapid.Generator[LawSpecValue] {
				return lsNativeGeneratorValues(integer, rapid.IntRange(40, 100))
			},
			"Box": func(_ *lawSpecSchema, _ lawSpecTypeRef, _ int, _ map[string]*lawSpecSymbol, arguments []*rapid.Generator[LawSpecValue]) *rapid.Generator[LawSpecValue] {
				child := lsNativeGeneratorArguments(integer, arguments[0])
				return lsNativeGeneratorValues(box, rapid.Map(child, func(n int) nativeBox { return nativeBox{n} }))
			},
		}
		generator := lsCheckedDataStrategyWithAttempts(schema, box.typeRef, bits, 12, 3,
			nil, nil, checkedScalar, factories)
		lsRapidCheck(t, 30, func(t *rapid.T) {
			n := box.toNative(generator.Draw(t, "native box").requireValue()).value
			if n < 40 || n > 100 {
				t.Fatalf("custom native distribution lost: %d", n)
			}
		})
		factories["Int8"] = func(*lawSpecSchema, lawSpecTypeRef, int, map[string]*lawSpecSymbol, []*rapid.Generator[LawSpecValue]) *rapid.Generator[LawSpecValue] {
			return lsNativeGeneratorValues(integer, rapid.Just(999))
		}
		for _, reference := range []lawSpecTypeRef{lsNamed("Int8"), box.typeRef} {
			bad := lsCheckedDataStrategyWithAttempts(schema, reference, bits, 12, 3, nil, nil, checkedScalar, factories)
			result := bad.Example(1)
			if result.rejected || !strings.Contains(fmt.Sprint(result.problem), "native generator Int8") {
				t.Fatalf("invalid native value was not a contextual failure: %+v", result)
			}
		}
		positive := positiveSchema(positivePredicate)
		invalid := LawSpecValue{"Positive", lawSpecData{"Positive::Make", []LawSpecValue{lsInteger("Int8", "0")}}}
		witness := LawSpecValue{"Positive", lawSpecData{"Positive::Make", []LawSpecValue{lsInteger("Int8", "1")}}}
		contractFactory := func(*lawSpecSchema, lawSpecTypeRef, int, map[string]*lawSpecSymbol, []*rapid.Generator[LawSpecValue]) *rapid.Generator[LawSpecValue] {
			return rapid.Just(invalid)
		}
		failure := lsCheckedDataStrategyWithAttempts(positive, lsNamed("Positive"), bits, 12, 3,
			nil, []LawSpecValue{witness}, checkedScalar, map[string]lawSpecNativeFactory{"Positive": contractFactory}).Example(1)
		if failure.rejected || !strings.Contains(fmt.Sprint(failure.problem), "native generator Positive") {
			t.Fatalf("custom constructor contract failure was rejected or repaired: %+v", failure)
		}

	}
}

func TestNativeShrink(t *testing.T) {
	if os.Getenv("LAWSPEC_NATIVE_SHRINK") == "" {
		t.Skip("deliberate failing property")
	}
	schema, integer, box := nativeGeneratorFixture(64)
	factories := map[string]lawSpecNativeFactory{
		"Int8": func(*lawSpecSchema, lawSpecTypeRef, int, map[string]*lawSpecSymbol, []*rapid.Generator[LawSpecValue]) *rapid.Generator[LawSpecValue] {
			return lsNativeGeneratorValues(integer, rapid.IntRange(40, 100))
		},
		"Box": func(_ *lawSpecSchema, _ lawSpecTypeRef, _ int, _ map[string]*lawSpecSymbol, args []*rapid.Generator[LawSpecValue]) *rapid.Generator[LawSpecValue] {
			return lsNativeGeneratorValues(box, rapid.Map(lsNativeGeneratorArguments(integer, args[0]), func(n int) nativeBox { return nativeBox{n} }))
		},
	}
	generator := lsCheckedDataStrategyWithAttempts(schema, box.typeRef, 64, 12, 3, nil, nil, checkedScalar, factories)
	rapid.Check(t, func(t *rapid.T) {
		n := box.toNative(generator.Draw(t, "box").requireValue()).value
		if n >= 61 {
			t.Fatalf("minimal_native=%d", n)
		}
	})
}

func TestNativeInvalidShrink(t *testing.T) {
	if os.Getenv("LAWSPEC_NATIVE_INVALID_SHRINK") == "" {
		t.Skip("deliberate failing property")
	}
	schema, integer, _ := nativeGeneratorFixture(64)
	factory := func(*lawSpecSchema, lawSpecTypeRef, int, map[string]*lawSpecSymbol, []*rapid.Generator[LawSpecValue]) *rapid.Generator[LawSpecValue] {
		return lsNativeGeneratorValues(integer, rapid.Map(rapid.IntRange(0, 100), func(n int) int {
			if n == 0 {
				return 999
			}
			return n
		}))
	}
	generator := lsCheckedDataStrategyWithAttempts(schema, lsNamed("Int8"), 64, 12, 3, nil, nil, checkedScalar,
		map[string]lawSpecNativeFactory{"Int8": factory})
	var observed any
	defer func() {
		if observed == nil {
			t.Error("invalid native shrink did not reach the callback")
		}
		fmt.Printf("observed_invalid_shrink=%v\n", observed)
	}()
	rapid.Check(t, func(t *rapid.T) {
		result := generator.Draw(t, "integer")
		if result.problem != nil {
			observed = result.problem
			t.Fatalf("native_error_reached_callback=%v", result.problem)
		}
		t.Fatalf("valid_sample=%v", result.value)
	})
}

func TestNativeExhausted(t *testing.T) {
	if os.Getenv("LAWSPEC_NATIVE_EMPTY") == "" {
		t.Skip("deliberate exhausted property")
	}
	schema, integer, _ := nativeGeneratorFixture(64)
	factory := func(*lawSpecSchema, lawSpecTypeRef, int, map[string]*lawSpecSymbol, []*rapid.Generator[LawSpecValue]) *rapid.Generator[LawSpecValue] {
		return lsNativeGeneratorValues(integer, rapid.IntRange(1, 2).Filter(func(int) bool { return false }))
	}
	generator := lsCheckedDataStrategyWithAttempts(schema, lsNamed("Int8"), 64, 12, 3, nil,
		[]LawSpecValue{lsInteger("Int8", "1")}, checkedScalar, map[string]lawSpecNativeFactory{"Int8": factory})
	rapid.Check(t, func(t *rapid.T) { generator.Draw(t, "empty").requireValue() })
}

func TestNativePhantomEmpty(t *testing.T) {
	for _, bits := range []int{32, 64} {
		schema := lsNewSchema([]lawSpecDataSchema{
			{"Empty", 0, nil},
			{"Phantom", 1, []lawSpecConstructorSchema{{"Phantom", []lawSpecFieldSchema{{"value", lsNamed("Int8")}}}}},
		}, []string{"Int8"})
		reference := lsNamed("Phantom", lsNamed("Empty"))
		factory := func(_ *lawSpecSchema, _ lawSpecTypeRef, _ int, _ map[string]*lawSpecSymbol, children []*rapid.Generator[LawSpecValue]) *rapid.Generator[LawSpecValue] {
			if len(children) != 1 {
				panic("expected one phantom parameter")
			}
			wrap := func(n int) LawSpecValue {
				return schema.construct(reference, "Phantom", []LawSpecValue{lsInteger("Int8", fmt.Sprint(n))}, bits)
			}
			if os.Getenv("LAWSPEC_NATIVE_PHANTOM_EMPTY") != "" {
				return rapid.Map(children[0], func(LawSpecValue) LawSpecValue { return wrap(40) })
			}
			return rapid.Map(rapid.IntRange(40, 100), wrap)
		}
		generator := lsCheckedDataStrategyWithAttempts(schema, reference, bits, 32, 3, nil, nil, checkedScalar,
			map[string]lawSpecNativeFactory{"Phantom": factory})
		last := 0
		defer func() { fmt.Printf("minimal_phantom=%d\n", last) }()
		rapid.Check(t, func(t *rapid.T) {
			value := generator.Draw(t, "phantom").requireValue()
			n := int(value.Data.(lawSpecData).fields[0].Data.(*big.Int).Int64())
			last = n
			if n < 40 || n > 100 {
				t.Fatalf("lost native distribution: %d", n)
			}
			if os.Getenv("LAWSPEC_NATIVE_PHANTOM_SHRINK") != "" && n > 60 {
				t.Fatalf("native phantom threshold: %d", n)
			}
		})
	}
}

func TestNativeEmptyRoot(t *testing.T) {
	schema := lsNewSchema([]lawSpecDataSchema{{"Empty", 0, nil}}, nil)
	defer func() {
		if problem := recover(); problem == nil || !strings.Contains(fmt.Sprint(problem), "no value of Empty") {
			t.Fatalf("empty root did not fail contextually: %v", problem)
		}
	}()
	lsCheckedDataStrategyWithAttempts(schema, lsNamed("Empty"), 64, 32, 3, nil, nil, checkedScalar)
}
