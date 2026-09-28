package fixture

import (
	"fmt"
	"os"
	"testing"

	"pgregory.net/rapid"
)

func schemaScalar(name string) *rapid.Generator[LawSpecValue] {
	switch name {
	case "Bool":
		return rapid.Map(rapid.Bool(), lsBool)
	case "Int8":
		return rapid.Map(rapid.Int8(), func(value int8) LawSpecValue {
			return lsInteger("Int8", fmt.Sprint(value))
		})
	case "Unit":
		return rapid.Just(lsAbsent("Unit"))
	default:
		panic("unexpected scalar generator: " + name)
	}
}

func schemaNodes(value LawSpecValue) int {
	count := 1
	switch data := value.Data.(type) {
	case lawSpecData:
		for _, child := range data.fields {
			count += schemaNodes(child)
		}
	case []LawSpecValue:
		for _, child := range data {
			count += schemaNodes(child)
		}
	case lawSpecPresence:
		if data.value != nil {
			count += schemaNodes(*data.value)
		}
	}
	return count
}

func schemaDefinition(name string, fields ...lawSpecTypeRef) lawSpecDataSchema {
	payload := make([]lawSpecFieldSchema, len(fields))
	for index, field := range fields {
		payload[index] = lawSpecFieldSchema{fmt.Sprintf("field%d", index), field}
	}
	return lawSpecDataSchema{name, 0, []lawSpecConstructorSchema{{name + "::Make", payload}}}
}

func TestDataGeneratorBudgets(t *testing.T) {
	for _, bits := range []int{32, 64} {
		definitions := []lawSpecDataSchema{schemaDefinition("Deep0")}
		for index := 1; index <= 5; index++ {
			definitions = append(definitions, schemaDefinition(fmt.Sprintf("Deep%d", index),
				lsNamed(fmt.Sprintf("Deep%d", index-1))))
		}
		fields := []lawSpecTypeRef{lsNamed("Deep5")}
		for index := 0; index < 9; index++ {
			fields = append(fields, lsNamed("Bool"))
		}
		definitions = append(definitions, schemaDefinition("Uneven", fields...))
		schema := lsNewSchema(definitions, []string{"Bool"})
		typeRef := lsNamed("Uneven")
		expectSchemaPanic(t, "node budget", func() {
			lsDataStrategy(schema, typeRef, bits, 15, schemaScalar)
		})
		generator := lsDataStrategy(schema, typeRef, bits, 16, schemaScalar)
		rapid.Check(t, func(t *rapid.T) {
			value := generator.Draw(t, "uneven")
			schema.validate(typeRef, value, bits)
			if schemaNodes(value) != 16 {
				t.Fatal("incorrect product node count")
			}
		})
		listType := lsNamed("List", lsNamed("Deep5"))
		lists := lsDataStrategy(schema, listType, bits, 7, schemaScalar)
		seen := false
		for seed := 1; seed <= 100; seed++ {
			value := lists.Example(seed)
			schema.validate(listType, value, bits)
			if len(value.Data.([]LawSpecValue)) == 1 {
				seen = true
				if schemaNodes(value) != 7 {
					t.Fatal("incorrect deep singleton cost")
				}
			}
		}
		if !seen {
			t.Fatal("deep singleton was excluded from the domain")
		}
	}
}

func TestDataGeneratorEmptyDomains(t *testing.T) {
	schema := lsNewSchema([]lawSpecDataSchema{{"Empty", 0, nil}}, []string{"Unit"})
	empty := lsNamed("Empty")
	expectSchemaPanic(t, "node budget", func() {
		lsDataStrategy(schema, empty, 64, 16, schemaScalar)
	})
	for _, name := range []string{"Maybe", "Nullable", "Optional", "List"} {
		typeRef := lsNamed(name, empty)
		expectSchemaPanic(t, "positive", func() {
			lsDataStrategy(schema, typeRef, 64, 0, schemaScalar)
		})
		value := lsDataStrategy(schema, typeRef, 64, 1, schemaScalar).Example(1)
		schema.validate(typeRef, value, 64)
		if schemaNodes(value) != 1 {
			t.Fatal("absence must cost exactly one node")
		}
	}
	typeRef := lsNamed("Either", empty, lsNamed("Unit"))
	expectSchemaPanic(t, "node budget", func() {
		lsDataStrategy(schema, typeRef, 64, 1, schemaScalar)
	})
	value := lsDataStrategy(schema, typeRef, 64, 2, schemaScalar).Example(1)
	schema.validate(typeRef, value, 64)
	if value.Data.(lawSpecData).tag != "Either::Right" || schemaNodes(value) != 2 {
		t.Fatal("incorrect Either constructor cost")
	}
}

func TestDataGeneratorRecursiveValues(t *testing.T) {
	schema := lawSpecDataSchemaRegistry()
	typeRef := lsNamed("Tree", lsNamed("Int8"))
	for _, bits := range []int{32, 64} {
		generator := lsDataStrategy(schema, typeRef, bits, 32, schemaScalar)
		rapid.Check(t, func(t *rapid.T) {
			value := generator.Draw(t, "tree")
			schema.validate(typeRef, value, bits)
			if schemaNodes(value) > 32 {
				t.Fatal("recursive value exceeded node budget")
			}
		})
	}
}

// The integration runner expects these properties to fail after native shrinking.
func TestDataShrinkLength(t *testing.T) {
	if os.Getenv("LAWSPEC_EXPECT_SHRINK") != "1" {
		t.Skip("run by the expected-failure integration check")
	}
	schema := lsNewSchema(nil, []string{"Unit"})
	typeRef := lsNamed("List", lsNamed("Unit"))
	generator := lsDataStrategy(schema, typeRef, 64, 10, schemaScalar)
	rapid.Check(t, func(t *rapid.T) {
		value := generator.Draw(t, "list")
		schema.validate(typeRef, value, 64)
		if schemaNodes(value) > 10 {
			t.Fatal("invalid shrink node count")
		}
		if length := len(value.Data.([]LawSpecValue)); length > 4 {
			t.Fatalf("minimal_length=%d", length)
		}
	})
}

func TestDataShrinkTree(t *testing.T) {
	if os.Getenv("LAWSPEC_EXPECT_SHRINK") != "1" {
		t.Skip("run by the expected-failure integration check")
	}
	schema := lawSpecDataSchemaRegistry()
	typeRef := lsNamed("Tree", lsNamed("Int8"))
	generator := lsDataStrategy(schema, typeRef, 64, 32, schemaScalar)
	var positive func(LawSpecValue) bool
	positive = func(value LawSpecValue) bool {
		data := value.Data.(lawSpecData)
		if data.tag == "ctor::Leaf" {
			return data.fields[0].Data.(*LawSpecBigInt).Sign() > 0
		}
		for _, child := range data.fields[0].Data.([]LawSpecValue) {
			if positive(child) {
				return true
			}
		}
		return false
	}
	rapid.Check(t, func(t *rapid.T) {
		value := generator.Draw(t, "tree")
		schema.validate(typeRef, value, 64)
		if schemaNodes(value) > 32 {
			t.Fatal("invalid shrink node count")
		}
		if positive(value) {
			t.Fatalf("minimal_tree=%v", value)
		}
	})
}
