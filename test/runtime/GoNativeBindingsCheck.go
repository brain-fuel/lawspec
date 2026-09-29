package shapes

import (
	"fmt"
	"strings"
	"testing"
)

func TestNativeCodecs(t *testing.T) {
	for _, bits := range []int{32, 64} {
		schema := lawSpecDataSchemaRegistry()
		symbols := map[string]*lawSpecSymbol{}
		raw := lawSpecNativeBoxCodec(schema, bits, lsScalarCodec[[]uint16](schema, bits, "Utf16Text"), symbols)
		value := Wrapped[[]uint16]{[]uint16{0xd800, 0, 0xdfff}}
		if !lsSchemaEqual(raw.fromNative(value), raw.fromNative(raw.toNative(raw.fromNative(value)))) {
			t.Fatal("raw UTF-16 changed in native generic conversion")
		}
		bytes := lawSpecNativeBoxCodec(schema, bits, lsScalarCodec[[]byte](schema, bits, "Bytes"), symbols)
		data := Wrapped[[]byte]{[]byte{0, 255, 128}}
		if !lsSchemaEqual(bytes.fromNative(data), bytes.fromNative(bytes.toNative(bytes.fromNative(data)))) {
			t.Fatal("native byte conversion was lossy")
		}
		symbol := lawSpecNativeBoxCodec(schema, bits, lsScalarCodec[*LawSpecSymbol](schema, bits, "Symbol"), symbols)
		one := Wrapped[*LawSpecSymbol]{lsSymbol("one", "same", symbols).Data.(*lawSpecSymbol)}
		two := Wrapped[*LawSpecSymbol]{lsSymbol("two", "same", symbols).Data.(*lawSpecSymbol)}
		if lsSchemaEqual(symbol.fromNative(one), symbol.fromNative(two)) {
			t.Fatal("Symbol descriptions replaced identity")
		}
		if symbol.toNative(symbol.fromNative(one)).Stored != one.Stored {
			t.Fatal("Symbol identity changed")
		}
		text := lawSpecNativeTreeCodec(schema, bits, lsScalarCodec[string](schema, bits, "Text"), symbols)
		func() {
			defer func() {
				if problem := recover(); problem == nil || !strings.Contains(fmt.Sprint(problem), "native.shapes::type::Tree::Leaf.item") {
					t.Fatalf("missing canonical field context for invalid native text: %v", problem)
				}
			}()
			text.fromNative(Item[string]{string([]byte{255})})
		}()
	}
}

func TestNativeConstructorContracts(t *testing.T) {
	for _, bits := range []int{32, 64} {
		original := lawSpecDataSchemaRegistry()
		definitions := []lawSpecDataSchema{}
		primitives := []string{}
		for _, definition := range original.definitions {
			definitions = append(definitions, definition)
		}
		for name, arity := range original.arity {
			if _, custom := original.definitions[name]; !custom && arity == 0 {
				primitives = append(primitives, name)
			}
		}
		schema := lsNewSchemaWithContracts(definitions, primitives, []lawSpecConstructorContract{
			{"native.shapes::type::Box::Box", []lawSpecFieldPredicate{
				func(_ *lawSpecSchema, args []lawSpecTypeRef, fields []LawSpecValue,
					width int, symbols map[string]*lawSpecSymbol) bool {
					if args[0].key() != "Symbol" || width != bits {
						t.Fatal("lost generic arguments or machine profile")
					}
					return lsEqual(fields[0], lsSymbol("fixture", "same", symbols))
				},
			}},
		})
		symbols := map[string]*lawSpecSymbol{}
		codec := lawSpecNativeBoxCodec(schema, bits, lsScalarCodec[*LawSpecSymbol](schema, bits, "Symbol"), symbols)
		valid := Wrapped[*LawSpecSymbol]{lsSymbol("fixture", "same", symbols).Data.(*lawSpecSymbol)}
		if codec.toNative(codec.fromNative(valid)).Stored != valid.Stored {
			t.Fatal("constructor contract lost the Symbol context")
		}
		invalid := Wrapped[*LawSpecSymbol]{lsSymbol("different", "same", symbols).Data.(*lawSpecSymbol)}
		func() {
			defer func() {
				if problem := recover(); problem == nil {
					t.Fatal("invalid native constructor passed its field contract")
				} else if _, rejected := problem.(lawSpecRefinementViolation); !rejected {
					t.Fatalf("expected contextual refinement violation, got %T: %v", problem, problem)
				}
			}()
			codec.fromNative(invalid)
		}()
	}
}
