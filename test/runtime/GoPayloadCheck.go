package fixture

import (
	"fmt"
	"math/big"
	"strings"
	"testing"
)

func payloadConstructor(tag string, types ...lawSpecTypeRef) lawSpecConstructorSchema {
	fields := make([]lawSpecFieldSchema, len(types))
	for index, ty := range types {
		fields[index] = lawSpecFieldSchema{fmt.Sprintf("field%d", index), ty}
	}
	return lawSpecConstructorSchema{tag, fields}
}

func payloadSchema() *lawSpecSchema {
	a, b, integer := lsParameter(0), lsParameter(1), lsNamed("Int8")
	return lsNewSchemaWithContracts([]lawSpecDataSchema{
		{"Tree", 1, []lawSpecConstructorSchema{
			payloadConstructor("Tree::Leaf", a, integer),
			payloadConstructor("Tree::Forest", lsNamed("List", lsNamed("Tree", a))),
		}},
		{"Pair", 2, []lawSpecConstructorSchema{payloadConstructor("Pair::Pair", a, b)}},
		{"Nest", 1, []lawSpecConstructorSchema{
			payloadConstructor("Nest::Stop", a),
			payloadConstructor("Nest::Next", lsNamed("Nest", lsNamed("List", a))),
		}},
		{"Phantom", 1, []lawSpecConstructorSchema{payloadConstructor("Phantom::Tag")}},
		{"A", 2, []lawSpecConstructorSchema{
			payloadConstructor("A::End", a), payloadConstructor("A::Next", lsNamed("B", b, a)),
		}},
		{"B", 2, []lawSpecConstructorSchema{
			payloadConstructor("B::End", a), payloadConstructor("B::Next", lsNamed("A", b, a)),
		}},
		{"Wrapped", 1, []lawSpecConstructorSchema{
			payloadConstructor("Wrapped::Wrap", lsNamed("Nullable", lsNamed("Optional", lsNamed("List", a)))),
		}},
		{"Checked", 1, []lawSpecConstructorSchema{payloadConstructor("Checked::Value", a)}},
		{"SymbolBox", 1, []lawSpecConstructorSchema{payloadConstructor("SymbolBox::Value", a)}},
	}, []string{"Int8", "Bool", "Symbol"}, []lawSpecConstructorContract{
		{"SymbolBox::Value", []lawSpecFieldPredicate{
			func(s *lawSpecSchema, args []lawSpecTypeRef, fields []LawSpecValue, bits int, symbols map[string]*lawSpecSymbol) bool {
				return lsEqual(fields[0], lsSymbol("shared", "description", symbols))
			},
		}},
		{"Checked::Value", []lawSpecFieldPredicate{
			func(s *lawSpecSchema, args []lawSpecTypeRef, fields []LawSpecValue, bits int, symbols map[string]*lawSpecSymbol) bool {
				return lsTruth(payloadPositive(fields[0]))
			},
		}},
	})
}

func payloadNumber(value int) LawSpecValue { return lsInteger("Int8", fmt.Sprint(value)) }
func payloadData(ty lawSpecTypeRef, tag string, fields ...LawSpecValue) LawSpecValue {
	return LawSpecValue{ty.key(), lawSpecData{tag, fields}}
}
func payloadList(ty lawSpecTypeRef, values ...LawSpecValue) LawSpecValue {
	return LawSpecValue{lsNamed("List", ty).key(), values}
}
func payloadPositive(value LawSpecValue) LawSpecValue {
	return lsBool(value.Data.(*big.Int).Sign() > 0)
}
func payloadNegative(value LawSpecValue) LawSpecValue {
	return lsBool(value.Data.(*big.Int).Sign() < 0)
}
func payloadUnused(value LawSpecValue) LawSpecValue { panic("unstored callback invoked") }
func payloadFails(t *testing.T, message string, operation func()) {
	t.Helper()
	defer func() {
		problem := recover()
		if problem == nil || !strings.Contains(fmt.Sprint(problem), message) {
			t.Fatalf("expected %q, got %v", message, problem)
		}
	}()
	operation()
}

func TestPayloadTraversal(t *testing.T) {
	for _, bits := range []int{32, 64} {
		t.Run(fmt.Sprint(bits), func(t *testing.T) {
			schema := payloadSchema()
			integer := lsNamed("Int8")
			tree := lsNamed("Tree", integer)
			check := func(ty lawSpecTypeRef, value LawSpecValue, expected bool, predicates ...func(LawSpecValue) LawSpecValue) {
				t.Helper()
				if actual := lsTruth(schema.allPayloads(ty, value, predicates, bits)); actual != expected {
					t.Fatalf("%s: got %v, want %v", ty.key(), actual, expected)
				}
			}
			for _, number := range []int{1, 0} {
				deep := payloadData(tree, "Tree::Leaf", payloadNumber(number), payloadNumber(-128))
				for depth := 0; depth < 40; depth++ {
					deep = payloadData(tree, "Tree::Forest", payloadList(tree, deep))
				}
				check(tree, deep, number > 0, payloadPositive)
				pair := lsNamed("Pair", integer, integer)
				check(pair, payloadData(pair, "Pair::Pair", payloadNumber(1), payloadNumber(-number)),
					number > 0, payloadPositive, payloadNegative)
				root, swapped := lsNamed("A", integer, integer), lsNamed("B", integer, integer)
				check(root, payloadData(root, "A::Next", payloadData(swapped, "B::End", payloadNumber(-number))),
					number > 0, payloadPositive, payloadNegative)
				nest := lsNamed("Nest", integer)
				inner := lsNamed("Nest", lsNamed("List", integer))
				check(nest, payloadData(nest, "Nest::Next", payloadData(inner, "Nest::Stop",
					payloadList(integer, payloadNumber(1), payloadNumber(number)))), number > 0, payloadPositive)
			}
			phantom := lsNamed("Phantom", integer)
			check(phantom, payloadData(phantom, "Phantom::Tag"), true, payloadUnused)
			check(lsNamed("List", integer), payloadList(integer), true, payloadUnused)
			maybe := lsNamed("Maybe", integer)
			check(maybe, payloadData(maybe, "Maybe::Nothing"), true, payloadUnused)
			check(maybe, payloadData(maybe, "Maybe::Just", payloadNumber(1)), true, payloadPositive)
			either := lsNamed("Either", integer, integer)
			check(either, payloadData(either, "Either::Left", payloadNumber(1)), true, payloadPositive, payloadUnused)
			check(either, payloadData(either, "Either::Right", payloadNumber(-1)), true, payloadUnused, payloadNegative)
			wrapped := lsNamed("Wrapped", integer)
			optional := lsNamed("Optional", lsNamed("List", integer))
			nullable := lsNamed("Nullable", optional)
			absent := lsPresent(optional.key(), nil)
			for _, value := range []LawSpecValue{lsPresent(nullable.key(), nil), lsPresent(nullable.key(), &absent)} {
				check(wrapped, payloadData(wrapped, "Wrapped::Wrap", value), true, payloadUnused)
			}
			items := payloadList(integer, payloadNumber(0))
			present := lsPresent(optional.key(), &items)
			check(wrapped, payloadData(wrapped, "Wrapped::Wrap", lsPresent(nullable.key(), &present)), false, payloadPositive)
			// A slot containing Optional is passed whole, not recursively flattened.
			whole := lsNamed("List", optional)
			check(whole, payloadList(optional, absent), true, func(value LawSpecValue) LawSpecValue {
				if value.Type != optional.key() || value.Data.(lawSpecPresence).value != nil {
					t.Fatal("declared argument was flattened")
				}
				return lsBool(true)
			})
			calls := 0
			check(lsNamed("List", integer), payloadList(integer, payloadNumber(0), payloadNumber(1)), false,
				func(value LawSpecValue) LawSpecValue { calls++; return payloadPositive(value) })
			if calls != 1 {
				t.Fatal("false predicate did not short-circuit")
			}
			// Snapshot callbacks before execution; one callback must not replace another.
			pair := lsNamed("Pair", integer, integer)
			callbacks := []func(LawSpecValue) LawSpecValue{nil, payloadNegative}
			callbacks[0] = func(value LawSpecValue) LawSpecValue {
				callbacks[1] = payloadUnused
				return payloadPositive(value)
			}
			check(pair, payloadData(pair, "Pair::Pair", payloadNumber(1), payloadNumber(-1)), true, callbacks...)
		})
	}
}

func TestPayloadFailures(t *testing.T) {
	for _, bits := range []int{32, 64} {
		schema := payloadSchema()
		integer := lsNamed("Int8")
		tree := lsNamed("Tree", integer)
		leaf := payloadData(tree, "Tree::Leaf", payloadNumber(1), payloadNumber(-128))
		call := func(ty lawSpecTypeRef, value LawSpecValue, predicates ...func(LawSpecValue) LawSpecValue) {
			schema.allPayloads(ty, value, predicates, bits)
		}
		payloadFails(t, "Tree::Leaf.field0: callback fault", func() {
			call(tree, leaf, func(LawSpecValue) LawSpecValue { panic("callback fault") })
		})
		payloadFails(t, "Tree::Leaf.field0", func() {
			call(tree, leaf, func(LawSpecValue) LawSpecValue { return payloadNumber(1) })
		})
		payloadFails(t, "arity", func() { call(tree, leaf) })
		payloadFails(t, "nil payload predicate", func() { call(tree, leaf, nil) })
		payloadFails(t, "require a data type", func() { call(integer, payloadNumber(1)) })
		calls := 0
		never := func(LawSpecValue) LawSpecValue { calls++; return lsBool(true) }
		payloadFails(t, "Tree::Leaf.field1", func() {
			call(tree, payloadData(tree, "Tree::Leaf", payloadNumber(1), payloadNumber(128)), never)
		})
		checked := lsNamed("Checked", integer)
		payloadFails(t, "constructor field contract rejected", func() {
			call(checked, payloadData(checked, "Checked::Value", payloadNumber(0)), never)
		})
		if calls != 0 {
			t.Fatal("callback ran before whole-value validation")
		}
		// Go permits cyclic slices: validation must reject them before traversal.
		children := make([]LawSpecValue, 1)
		children[0] = payloadData(tree, "Tree::Forest", payloadList(tree, children...))
		payloadFails(t, "cyclic structural value", func() { call(tree, children[0], never) })
	}
}

func TestPayloadSymbols(t *testing.T) {
	for _, bits := range []int{32, 64} {
		schema := payloadSchema()
		symbols := map[string]*lawSpecSymbol{}
		typeRef := lsNamed("List", lsNamed("Symbol"))
		box := lsNamed("SymbolBox", lsNamed("Symbol"))
		value := payloadData(box, "SymbolBox::Value", lsSymbol("shared", "description", symbols))
		if !lsTruth(schema.allPayloads(box, value, []func(LawSpecValue) LawSpecValue{
			func(LawSpecValue) LawSpecValue { return lsBool(true) },
		}, bits, symbols)) {
			t.Fatal("constructor predicate lost shared Symbol context")
		}
		for _, id := range []string{"shared", "different"} {
			value := payloadList(lsNamed("Symbol"), lsSymbol(id, "description", symbols))
			predicate := func(value LawSpecValue) LawSpecValue {
				return lsBool(lsEqual(value, lsSymbol("shared", "description", symbols)))
			}
			if lsTruth(schema.allPayloads(typeRef, value, []func(LawSpecValue) LawSpecValue{predicate}, bits, symbols)) != (id == "shared") {
				t.Fatal("Symbol identity lost")
			}
		}
	}
}
