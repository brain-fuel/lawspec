package fixture

import (
	"fmt"
	"strings"
	"testing"
)

func expectSchemaPanic(t *testing.T, fragment string, operation func()) {
	t.Helper()
	defer func() {
		problem := recover()
		if problem == nil || !strings.Contains(fmt.Sprint(problem), fragment) {
			t.Fatalf("expected failure containing %q, got %v", fragment, problem)
		}
	}()
	operation()
}

func TestSchemaValues(t *testing.T) {
	for _, bits := range []int{32, 64} {
		schema := lawSpecDataSchemaRegistry()
		tree := lsNamed("Tree", lsNamed("Int8"))
		leaf := schema.construct(tree, "ctor::Leaf", []LawSpecValue{lsInteger("Int8", "127")}, bits)
		listType := lsNamed("List", tree)
		emptyList := schema.construct(listType, "List::Nil", nil, bits)
		cons := schema.construct(listType, "List::Cons", []LawSpecValue{leaf, emptyList}, bits)
		if !schema.equal(tree, cons.Data.([]LawSpecValue)[0], leaf, bits) {
			t.Fatal("List constructor lost its custom data element")
		}
		expectSchemaPanic(t, "Cons takes two", func() {
			schema.construct(listType, "List::Cons", nil, bits)
		})
		children := []LawSpecValue{leaf}
		branch := schema.construct(tree, "ctor::Branch", []LawSpecValue{
			{Type: "List Tree Int8", Data: children},
		}, bits)
		children[0] = LawSpecValue{}
		if !schema.equal(tree, branch, branch, bits) {
			t.Fatal("recursive value failed reflexivity")
		}
		if schema.equal(tree, leaf, branch, bits) {
			t.Fatal("constructor identity lost")
		}
		expectSchemaPanic(t, "ctor::Leaf.value", func() {
			schema.construct(tree, "ctor::Leaf", []LawSpecValue{lsInteger("Int8", "128")}, bits)
		})
		expectSchemaPanic(t, "ctor::Leaf.value", func() {
			schema.construct(tree, "ctor::Leaf", []LawSpecValue{lsBool(true)}, bits)
		})
		expectSchemaPanic(t, "wrong field count", func() {
			schema.construct(tree, "ctor::Leaf", nil, bits)
		})
		expectSchemaPanic(t, "unknown constructor", func() {
			schema.construct(tree, "ctor::Pair", nil, bits)
		})
		expectSchemaPanic(t, "unknown constructor", func() {
			schema.construct(lsNamed("Empty", lsNamed("Int8")), "anything", nil, bits)
		})
		floatTree := lsNamed("Tree", lsNamed("Float64"))
		floatLeaf := func(value LawSpecValue) LawSpecValue {
			return schema.construct(floatTree, "ctor::Leaf", []LawSpecValue{value}, bits)
		}
		nan := floatLeaf(lsFloating("Float64", "7ff8000000000000"))
		if schema.equal(floatTree, nan, nan, bits) {
			t.Fatal("NaN compared equal inside a data constructor")
		}
		positive := floatLeaf(lsFloating("Float64", "0000000000000000"))
		negative := floatLeaf(lsFloating("Float64", "8000000000000000"))
		if !schema.equal(floatTree, positive, negative, bits) {
			t.Fatal("signed zeros compared unequal")
		}
		symbolTree := lsNamed("Tree", lsNamed("Symbol"))
		symbols := map[string]*lawSpecSymbol{}
		symbolLeaf := func(id string) LawSpecValue {
			return schema.construct(symbolTree, "ctor::Leaf", []LawSpecValue{
				lsSymbol(id, "same description", symbols),
			}, bits)
		}
		if !schema.equal(symbolTree, symbolLeaf("a"), symbolLeaf("a"), bits) ||
			schema.equal(symbolTree, symbolLeaf("a"), symbolLeaf("b"), bits) {
			t.Fatal("Symbol identity was replaced with description equality")
		}
		maybe := lsNamed("Maybe", tree)
		inner := schema.construct(maybe, "Maybe::Nothing", nil, bits)
		outer := lsNamed("Maybe", maybe)
		absent := schema.construct(outer, "Maybe::Nothing", nil, bits)
		present := schema.construct(outer, "Maybe::Just", []LawSpecValue{inner}, bits)
		if schema.equal(outer, absent, present, bits) {
			t.Fatal("nested Maybe collapsed")
		}
		nullable := lsNamed("Nullable", lsNamed("Optional", tree))
		null := lsPresent(nullable.key(), nil)
		undefined := lsPresent("Optional Tree Int8", nil)
		value := lsPresent(nullable.key(), &undefined)
		if schema.equal(nullable, null, value, bits) {
			t.Fatal("nested interoperability absence collapsed")
		}
		expectSchemaPanic(t, "machineBits", func() {
			schema.validate(tree, leaf, 16)
		})
	}
}

func TestSchemaMetadata(t *testing.T) {
	typeRef := lsNamed("Int8")
	fields := []lawSpecFieldSchema{{"payload", typeRef}}
	definitions := []lawSpecDataSchema{{"Box", 0,
		[]lawSpecConstructorSchema{{"Box::Box", fields}},
	}}
	schema := lsNewSchema(definitions, []string{"Int8"})
	fields[0].typeRef = lsNamed("NotAType")
	value := schema.construct(lsNamed("Box"), "Box::Box",
		[]LawSpecValue{lsInteger("Int8", "1")}, 64)
	constructors, _ := schema.constructors(lsNamed("Box"))
	constructors[0].fields[0].typeRef = lsNamed("NotAType")
	schema.validate(lsNamed("Box"), value, 64)
	expectSchemaPanic(t, "unknown type", func() {
		lsNewSchema(definitions, []string{"Int8"})
	})
	expectSchemaPanic(t, "duplicate", func() {
		lsNewSchema([]lawSpecDataSchema{{"List", 0, nil}}, nil)
	})
	expectSchemaPanic(t, "unbound", func() {
		lsNewSchema([]lawSpecDataSchema{{"Bad", 0,
			[]lawSpecConstructorSchema{{"Bad::Bad",
				[]lawSpecFieldSchema{{"value", lsParameter(0)}},
			}},
		}}, nil)
	})
}
