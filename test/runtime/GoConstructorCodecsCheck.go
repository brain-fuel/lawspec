package fixture

import (
	"fmt"
	"strings"
	"testing"
)

func checkContractCodec[T any](t *testing.T, codec lawSpecCodec[T], value T) {
	t.Helper()
	logical := codec.fromNative(value)
	if !lsSchemaEqual(logical, codec.fromNative(codec.toNative(logical))) {
		t.Fatal("contract codec changed a round trip")
	}
}

func expectCodecRejection(t *testing.T, fragment string, operation func()) {
	t.Helper()
	defer func() {
		problem := recover()
		if _, ok := problem.(lawSpecRefinementViolation); !ok ||
			!strings.Contains(fmt.Sprint(problem), fragment) {
			t.Fatalf("expected typed rejection containing %q, got %T: %v", fragment, problem, problem)
		}
	}()
	operation()
}

func TestConstructorCodecContexts(t *testing.T) {
	for _, bits := range []int{32, 64} {
		t.Run(fmt.Sprint(bits), func(t *testing.T) {
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
				{"ctor::Leaf", []lawSpecFieldPredicate{
					func(_ *lawSpecSchema, args []lawSpecTypeRef, fields []LawSpecValue,
						width int, symbols map[string]*lawSpecSymbol) bool {
						if args[0].key() != "Symbol" || width != bits {
							t.Fatal("lost generic type or machine width")
						}
						return lsEqual(fields[0], lsSymbol("fixture", "same", symbols))
					},
				}},
			})
			symbols := map[string]*lawSpecSymbol{}
			identity := lsSymbol("fixture", "same", symbols).Data.(*lawSpecSymbol)
			element := lsScalarCodec[*LawSpecSymbol](schema, bits, "Symbol")
			tree := lawSpecTreeCodec(schema, bits, element, symbols)
			var leaf Tree[*LawSpecSymbol] = TreeLeaf[*LawSpecSymbol]{Value: identity}
			var branch Tree[*LawSpecSymbol] = TreeBranch[*LawSpecSymbol]{
				Children: []Tree[*LawSpecSymbol]{leaf, TreeBranch[*LawSpecSymbol]{
					Children: []Tree[*LawSpecSymbol]{leaf},
				}},
			}
			checkContractCodec(t, tree, branch)
			checkContractCodec(t, lsListCodec(schema, bits, tree, symbols), []Tree[*LawSpecSymbol]{branch})
			checkContractCodec(t, lsMaybeCodec(schema, bits, tree, symbols), LawSpecJust(branch))
			checkContractCodec(t, lsEitherCodec(schema, bits, tree, element, symbols),
				LawSpecLeft[Tree[*LawSpecSymbol], *LawSpecSymbol](branch))
			nullable := lsNullableCodec(schema, bits, tree, symbols)
			optional := lsOptionalCodec(schema, bits, nullable, symbols)
			checkContractCodec(t, optional, LawSpecOptional[LawSpecNullable[Tree[*LawSpecSymbol]]]{
				Present: true, Value: LawSpecNullable[Tree[*LawSpecSymbol]]{Present: true, Value: branch},
			})
			checkContractCodec(t, optional, LawSpecOptional[LawSpecNullable[Tree[*LawSpecSymbol]]]{})
			checkContractCodec(t, optional, LawSpecOptional[LawSpecNullable[Tree[*LawSpecSymbol]]]{Present: true})
			// Same description is insufficient at either boundary.
			var bad Tree[*LawSpecSymbol] = TreeLeaf[*LawSpecSymbol]{Value: &LawSpecSymbol{"same"}}
			expectCodecRejection(t, "ctor::Leaf predicate 1", func() { tree.fromNative(bad) })
			badLogical := LawSpecValue{tree.typeRef.key(), lawSpecData{"ctor::Leaf",
				[]LawSpecValue{{"Symbol", &LawSpecSymbol{"same"}}}}}
			expectCodecRejection(t, "ctor::Leaf predicate 1", func() { tree.toNative(badLogical) })
			expectCodecRejection(t, "ctor::Leaf predicate 1", func() {
				lawSpecTreeCodec(schema, bits, element).fromNative(branch)
			})
			schema.contracts["ctor::Leaf"] = []lawSpecFieldPredicate{
				func(*lawSpecSchema, []lawSpecTypeRef, []LawSpecValue, int, map[string]*lawSpecSymbol) bool {
					panic("codec evaluation marker")
				},
			}
			expectSchemaPanic(t, "codec evaluation marker", func() { tree.fromNative(branch) })
			expectSchemaPanic(t, "codec evaluation marker", func() { tree.toNative(badLogical) })
		})
	}
}
