package fixture

import (
	"flag"
	"fmt"
	"math/big"
	"os"
	"strings"
	"testing"

	"pgregory.net/rapid"
)

func TestRapidSettings(t *testing.T) {
	previous := flag.Lookup("rapid.checks").Value.String()
	for _, count := range []int{1, 7, 13} {
		draws := 0
		lsRapidCheck(t, count, func(t *rapid.T) {
			rapid.Bool().Draw(t, "value")
			draws++
		})
		if draws != count {
			t.Fatalf("got %d cases, expected %d", draws, count)
		}
		if flag.Lookup("rapid.checks").Value.String() != previous {
			t.Fatal("Rapid case setting was not restored")
		}
	}
	checkedPanic(t, "attempt limit must be positive", func() {
		lsBoundedFilter(rapid.Just(1), 0, func(int) bool { return true })
	})
	draws := 0
	source := rapid.Custom(func(t *rapid.T) int {
		draws++
		return rapid.Just(1).Draw(t, "constant")
	})
	checkedPanic(t, "failed to generate", func() {
		lsBoundedFilter(source, 2, func(int) bool { return false }).Example(1)
	})
	// Rapid 1.2.0 retries Custom five times and Example 1000 times.
	if draws != 2*5*1000 {
		t.Fatalf("unexpected bounded native draw count: %d", draws)
	}
}

func positiveSchema(predicate lawSpecFieldPredicate) *lawSpecSchema {
	return lsNewSchemaWithContracts([]lawSpecDataSchema{
		{"Positive", 0, []lawSpecConstructorSchema{{"Positive::Make",
			[]lawSpecFieldSchema{{"value", lsNamed("Int8")}}}}},
	}, []string{"Int8"}, []lawSpecConstructorContract{{"Positive::Make", []lawSpecFieldPredicate{predicate}}})
}

func positivePredicate(_ *lawSpecSchema, _ []lawSpecTypeRef, fields []LawSpecValue,
	_ int, _ map[string]*lawSpecSymbol) bool {
	return fields[0].Data.(*big.Int).Sign() > 0
}

func checkedScalar(string) *rapid.Generator[LawSpecValue] {
	return rapid.Map(rapid.Int8(), func(n int8) LawSpecValue {
		return lsInteger("Int8", fmt.Sprint(n))
	})
}

func TestCheckedStrategies(t *testing.T) {
	for _, bits := range []int{32, 64} {
		t.Run(fmt.Sprint(bits), func(t *testing.T) {
			schema := positiveSchema(positivePredicate)
			ref := lsNamed("List", lsNamed("Positive"))
			generator := lsCheckedDataStrategy(schema, ref, bits, 11, nil, nil, checkedScalar)
			rapid.Check(t, func(t *rapid.T) {
				value := generator.Draw(t, "values").requireValue()
				schema.validate(ref, value, bits)
				if lsDataNodes(value) > 11 {
					t.Fatal("node budget exceeded")
				}
				for _, child := range value.Data.([]LawSpecValue) {
					if child.Data.(lawSpecData).fields[0].Data.(*big.Int).Sign() <= 0 {
						t.Fatal("invalid checked value")
					}
				}
			})
			witness := schema.construct(lsNamed("Positive"), "Positive::Make",
				[]LawSpecValue{lsInteger("Int8", "7")}, bits)
			seeded := lsCheckedDataStrategy(schema, ref, bits, 11, nil,
				[]LawSpecValue{{ref.key(), []LawSpecValue{witness}}},
				func(string) *rapid.Generator[LawSpecValue] { return rapid.Just(lsInteger("Int8", "0")) })
			seen := false
			for seed := 1; seed <= 100; seed++ {
				value := seeded.Example(seed).requireValue()
				schema.validate(ref, value, bits)
				if len(value.Data.([]LawSpecValue)) > 1 {
					seen = true // Descendant seeds must work beyond the supplied singleton.
				}
			}
			if !seen {
				t.Fatal("nested typed witnesses did not populate new shapes")
			}
			invalid := LawSpecValue{ref.key(), []LawSpecValue{
				{"Positive", lawSpecData{"Positive::Make", []LawSpecValue{lsInteger("Int8", "0")}}},
			}}
			checkedPanic(t, "contract rejected", func() {
				lsCheckedDataStrategy(schema, ref, bits, 11, nil, []LawSpecValue{invalid}, checkedScalar)
			})
			checkedPanic(t, "require checked strategies", func() {
				lsDataStrategy(schema, ref, bits, 11, checkedScalar)
			})
			broken := positiveSchema(func(*lawSpecSchema, []lawSpecTypeRef, []LawSpecValue,
				int, map[string]*lawSpecSymbol) bool {
				panic("evaluator marker")
			})
			failure := lsCheckedDataStrategy(broken, lsNamed("Positive"), bits, 2,
				nil, nil, checkedScalar).Example(1)
			if failure.problem == nil || failure.rejected {
				t.Fatal("evaluation error was lost or rejected")
			}
			checkedPanic(t, "evaluator marker", func() { failure.requireValue() })
		})
	}
}

func TestCheckedSymbolContext(t *testing.T) {
	schema := lsNewSchemaWithContracts([]lawSpecDataSchema{
		{"Identity", 0, []lawSpecConstructorSchema{{"Identity::Make",
			[]lawSpecFieldSchema{{"value", lsNamed("Symbol")}}}}},
	}, []string{"Symbol"}, []lawSpecConstructorContract{{"Identity::Make", []lawSpecFieldPredicate{
		func(_ *lawSpecSchema, _ []lawSpecTypeRef, fields []LawSpecValue,
			_ int, symbols map[string]*lawSpecSymbol) bool {
			return lsEqual(fields[0], lsSymbol("fixture", "same", symbols))
		},
	}}})
	for _, bits := range []int{32, 64} {
		symbols := map[string]*lawSpecSymbol{}
		ref := lsNamed("Identity")
		witness := schema.construct(ref, "Identity::Make",
			[]LawSpecValue{lsSymbol("fixture", "same", symbols)}, bits, symbols)
		scalar := func(string) *rapid.Generator[LawSpecValue] {
			return rapid.Just(lsSymbol("other", "same", symbols))
		}
		gen := lsCheckedDataStrategy(schema, ref, bits, 2, symbols, []LawSpecValue{witness}, scalar)
		rapid.Check(t, func(t *rapid.T) {
			value := gen.Draw(t, "identity").requireValue()
			if !schema.equal(ref, witness, value, bits, symbols) {
				t.Fatal("Symbol fixture identity lost")
			}
		})
		checkedPanic(t, "contract rejected", func() {
			lsCheckedDataStrategy(schema, ref, bits, 2, map[string]*lawSpecSymbol{},
				[]LawSpecValue{witness}, scalar)
		})
	}
}

func TestCheckedSampleIsolation(t *testing.T) {
	schema := positiveSchema(func(_ *lawSpecSchema, _ []lawSpecTypeRef, fields []LawSpecValue,
		_ int, _ map[string]*lawSpecSymbol) bool {
		if fields[0].Data.(*big.Int).Sign() <= 0 {
			panic("sample marker")
		}
		return true
	})
	for _, bits := range []int{32, 64} {
		gen := lsCheckedDataStrategy(schema, lsNamed("Positive"), bits, 2, nil, nil, checkedScalar)
		valid, failed := 0, 0
		for seed := 1; seed <= 100; seed++ {
			value := gen.Example(seed)
			if value.problem != nil {
				failed++
				checkedPanic(t, "sample marker", func() { value.requireValue() })
			} else {
				valid++
				schema.validate(lsNamed("Positive"), value.requireValue(), bits)
			}
		}
		if valid == 0 || failed == 0 {
			t.Fatal("error state leaked across samples or errors were filtered out")
		}
	}
}

func TestCheckedStopsAfterError(t *testing.T) {
	boom := func(*lawSpecSchema, []lawSpecTypeRef, []LawSpecValue,
		int, map[string]*lawSpecSymbol) bool {
		panic("first field failed")
	}
	empty := func(*lawSpecSchema, []lawSpecTypeRef, []LawSpecValue,
		int, map[string]*lawSpecSymbol) bool {
		t.Fatal("later field was evaluated after an error")
		return false
	}
	schema := lsNewSchemaWithContracts([]lawSpecDataSchema{
		{"Broken", 0, []lawSpecConstructorSchema{{"Broken::Make", nil}}},
		{"Empty", 0, []lawSpecConstructorSchema{{"Empty::Make", nil}}},
		{"Pair", 0, []lawSpecConstructorSchema{{"Pair::Make",
			[]lawSpecFieldSchema{{"first", lsNamed("Broken")}, {"second", lsNamed("Empty")}}}}},
	}, nil, []lawSpecConstructorContract{
		{"Broken::Make", []lawSpecFieldPredicate{boom}}, {"Empty::Make", []lawSpecFieldPredicate{empty}},
	})
	for _, bits := range []int{32, 64} {
		gen := lsCheckedDataStrategy(schema, lsNamed("Pair"), bits, 3, nil, nil, checkedScalar)
		value := gen.Example(1)
		checkedPanic(t, "first field failed", func() { value.requireValue() })
	}
}

func checkedPanic(t *testing.T, text string, operation func()) {
	t.Helper()
	defer func() {
		if problem := recover(); problem == nil || !strings.Contains(fmt.Sprint(problem), text) {
			t.Fatalf("expected %q, got %v", text, problem)
		}
	}()
	operation()
}

func TestCheckedShrink(t *testing.T) {
	if os.Getenv("LAWSPEC_EXPECT_SHRINK") == "" {
		t.Skip("deliberate failing property")
	}
	schema := positiveSchema(positivePredicate)
	ref := lsNamed("List", lsNamed("Positive"))
	gen := lsCheckedDataStrategyWithAttempts(schema, ref, 64, 15, 2, nil, nil, checkedScalar)
	rapid.Check(t, func(t *rapid.T) {
		value := gen.Draw(t, "values").requireValue()
		schema.validate(ref, value, 64)
		values := value.Data.([]LawSpecValue)
		if len(values) >= 3 {
			payloads := []int64{}
			for _, child := range values {
				payloads = append(payloads, child.Data.(lawSpecData).fields[0].Data.(*big.Int).Int64())
			}
			t.Fatalf("minimal_values=%v", payloads)
		}
	})
}

func TestCheckedEmpty(t *testing.T) {
	if os.Getenv("LAWSPEC_EXPECT_EMPTY") == "" {
		t.Skip("deliberately uninhabited contract")
	}
	schema := positiveSchema(func(*lawSpecSchema, []lawSpecTypeRef, []LawSpecValue,
		int, map[string]*lawSpecSymbol) bool {
		return false
	})
	gen := lsCheckedDataStrategy(schema, lsNamed("Positive"), 64, 2, nil, nil, checkedScalar)
	rapid.Check(t, func(t *rapid.T) { gen.Draw(t, "impossible").requireValue() })
}
