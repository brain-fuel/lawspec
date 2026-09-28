package fixture

import (
	"fmt"
	"math/big"
	"strings"
	"testing"
)

func contractPanic(t *testing.T, fragment string, operation func()) {
	t.Helper()
	defer func() {
		if problem := recover(); problem == nil || !strings.Contains(fmt.Sprint(problem), fragment) {
			t.Fatalf("expected %q, got %v", fragment, problem)
		}
	}()
	operation()
}

func TestConstructorContracts(t *testing.T) {
	for _, bits := range []int{32, 64} {
		t.Run(fmt.Sprint(bits), func(t *testing.T) {
			calls := 0
			positive := func(_ *lawSpecSchema, args []lawSpecTypeRef, fields []LawSpecValue,
				width int, _ map[string]*lawSpecSymbol) bool {
				calls++
				if width != bits || args[0].key() != "Int8" {
					t.Fatal("lost profile or type arguments")
				}
				return fields[0].Data.(*big.Int).Sign() > 0
			}
			guarded := func(_ *lawSpecSchema, _ []lawSpecTypeRef, fields []LawSpecValue,
				_ int, _ map[string]*lawSpecSymbol) bool {
				// The prior predicate must reject zero before this division.
				new(big.Int).Quo(big.NewInt(1), fields[0].Data.(*big.Int))
				return true
			}
			identity := func(_ *lawSpecSchema, _ []lawSpecTypeRef, fields []LawSpecValue,
				_ int, symbols map[string]*lawSpecSymbol) bool {
				return lsEqual(fields[0], lsSymbol("fixture", "same", symbols))
			}
			definitions := []lawSpecDataSchema{
				{"Box", 1, []lawSpecConstructorSchema{{"Box::Box", []lawSpecFieldSchema{{"value", lsParameter(0)}}}}},
				{"Identity", 0, []lawSpecConstructorSchema{{"Identity::Identity", []lawSpecFieldSchema{{"value", lsNamed("Symbol")}}}}},
				{"Broken", 0, []lawSpecConstructorSchema{{"Broken::Broken", nil}}},
			}
			predicates := []lawSpecFieldPredicate{positive, guarded}
			contracts := []lawSpecConstructorContract{
				{"Box::Box", predicates},
				{"Identity::Identity", []lawSpecFieldPredicate{identity}},
				{"Broken::Broken", []lawSpecFieldPredicate{
					func(*lawSpecSchema, []lawSpecTypeRef, []LawSpecValue, int, map[string]*lawSpecSymbol) bool {
						panic("evaluation marker")
					},
				}},
			}
			schema := lsNewSchemaWithContracts(definitions, []string{"Int8", "Symbol"}, contracts)
			predicates[0] = guarded // Registration must own its callback slice.
			box := lsNamed("Box", lsNamed("Int8"))
			value := func(n string) LawSpecValue {
				return LawSpecValue{box.key(), lawSpecData{"Box::Box", []LawSpecValue{lsInteger("Int8", n)}}}
			}
			if !schema.hasContracts() || !schema.accepts(box, value("1"), bits) {
				t.Fatal("valid candidate rejected")
			}
			if schema.accepts(box, value("0"), bits) || schema.accepts(box, value("-1"), bits) {
				t.Fatal("invalid candidate accepted or predicate ordering lost")
			}
			before := calls
			contractPanic(t, "Box::Box.value", func() { schema.accepts(box, value("128"), bits) })
			if calls != before {
				t.Fatal("predicate ran before representation validation")
			}
			list := lsNamed("List", box)
			invalidList := LawSpecValue{list.key(), []LawSpecValue{value("0")}}
			if schema.accepts(list, invalidList, bits) {
				t.Fatal("nested rejection lost")
			}
			contractPanic(t, "List[0]: Box::Box predicate 1", func() { schema.validate(list, invalidList, bits) })
			contractPanic(t, "Broken::Broken predicate 1: evaluation marker", func() {
				schema.accepts(lsNamed("Broken"), LawSpecValue{"Broken", lawSpecData{"Broken::Broken", nil}}, bits)
			})
			symbols := map[string]*lawSpecSymbol{}
			id := lsNamed("Identity")
			native := schema.construct(id, "Identity::Identity",
				[]LawSpecValue{lsSymbol("fixture", "same", symbols)}, bits, symbols)
			if !schema.equal(id, native, native, bits, symbols) {
				t.Fatal("shared symbol identity lost")
			}
			if schema.accepts(id, native, bits) {
				t.Fatal("separate symbol contexts collapsed")
			}
			for _, container := range []string{"List", "Maybe", "Either", "Nullable", "Optional"} {
				ref := lsNamed(container, id)
				if container == "Either" {
					ref = lsNamed(container, id, box)
				}
				var wrapped LawSpecValue
				switch container {
				case "List":
					wrapped = LawSpecValue{ref.key(), []LawSpecValue{native}}
				case "Either":
					wrapped = LawSpecValue{ref.key(), lawSpecData{"Either::Left", []LawSpecValue{native}}}
				case "Maybe":
					wrapped = LawSpecValue{ref.key(), lawSpecData{"Maybe::Just", []LawSpecValue{native}}}
				default:
					wrapped = lsPresent(ref.key(), &native)
				}
				if !schema.accepts(ref, wrapped, bits, symbols) || schema.accepts(ref, wrapped, bits) {
					t.Fatalf("%s lost the symbol context", container)
				}
			}
			contractPanic(t, "unknown constructor contract", func() {
				lsNewSchemaWithContracts(definitions, []string{"Int8", "Symbol"},
					[]lawSpecConstructorContract{{"missing", nil}})
			})
			contractPanic(t, "duplicate", func() {
				lsNewSchemaWithContracts(definitions, []string{"Int8", "Symbol"}, append(contracts, contracts[0]))
			})
			contractPanic(t, "nil constructor predicate", func() {
				lsNewSchemaWithContracts(definitions, []string{"Int8", "Symbol"},
					[]lawSpecConstructorContract{{"Box::Box", []lawSpecFieldPredicate{nil}}})
			})
		})
	}
}
