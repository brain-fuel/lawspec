// Typed conversion bridges are independent of property-testing frameworks.
package RUNTIME_PACKAGE

import "fmt"

type lawSpecCodec[T any] struct {
	typeRef    lawSpecTypeRef
	toNative   func(LawSpecValue) T
	fromNative func(T) LawSpecValue
	encode     func(T, lawSpecPath) LawSpecValue
}

func lsNativeContext[T any](context string, operation func() T) (result T) {
	defer func() {
		if problem := recover(); problem != nil {
			message := fmt.Sprintf("%s: %v", context, problem)
			if _, rejected := problem.(lawSpecRefinementViolation); rejected {
				panic(lawSpecRefinementViolation{message})
			}
			panic(message)
		}
	}()
	return operation()
}

func lsCodec[T any](schema *lawSpecSchema, bits int, typeRef lawSpecTypeRef,
	toNative func(LawSpecValue) T, fromNative func(T, lawSpecPath) LawSpecValue, contexts ...map[string]*lawSpecSymbol) lawSpecCodec[T] {
	symbols := lsSchemaSymbols(contexts)
	schema.check(typeRef, 0)
	if bits != 32 && bits != 64 {
		panic("machineBits must be 32 or 64")
	}
	schema.checkNativeProfile(typeRef, bits)
	encode := func(value T, path lawSpecPath) LawSpecValue {
		return lsSchemaContext(typeRef.key(), func() LawSpecValue {
			return schema.validate(typeRef, fromNative(value, path), bits, symbols)
		})
	}
	return lawSpecCodec[T]{
		typeRef: typeRef,
		toNative: func(value LawSpecValue) T {
			return lsNativeContext(typeRef.key(), func() T {
				return toNative(schema.validate(typeRef, value, bits, symbols))
			})
		},
		fromNative: func(value T) LawSpecValue { return encode(value, lawSpecPath{}) },
		encode:     encode,
	}
}

// Opaque generic payloads retain validation while crossing application hooks.
func lsLogicalCodec(schema *lawSpecSchema, bits int, typeRef lawSpecTypeRef, contexts ...map[string]*lawSpecSymbol) lawSpecCodec[LawSpecValue] {
	return lsCodec(schema, bits, typeRef,
		func(value LawSpecValue) LawSpecValue { return value },
		func(value LawSpecValue, path lawSpecPath) LawSpecValue { return value }, contexts...)
}

func lsScalarCodec[T any](schema *lawSpecSchema, bits int, name string) lawSpecCodec[T] {
	lsCheckNativeProfile(name, bits)
	return lsCodec(schema, bits, lsNamed(name),
		func(value LawSpecValue) T {
			var native any
			switch name {
			case "Unit":
				native = LawSpecUnit{}
			case "Null":
				native = LawSpecNull{}
			case "Undefined":
				native = LawSpecUndefined{}
			default:
				native = lsToNative(name, value, bits)
			}
			return native.(T)
		},
		func(value T, path lawSpecPath) LawSpecValue {
			switch name {
			case "Unit":
				_ = any(value).(LawSpecUnit)
				return lsAbsent(name)
			case "Null":
				_ = any(value).(LawSpecNull)
				return lsAbsent(name)
			case "Undefined":
				_ = any(value).(LawSpecUndefined)
				return lsAbsent(name)
			default:
				return lsFromNative(name, value, bits)
			}
		})
}

func lsListCodec[T any](schema *lawSpecSchema, bits int, element lawSpecCodec[T], contexts ...map[string]*lawSpecSymbol) lawSpecCodec[[]T] {
	symbols := lsSchemaSymbols(contexts)
	typeRef := lsNamed("List", element.typeRef)
	return lsCodec(schema, bits, typeRef,
		func(value LawSpecValue) []T {
			values := value.Data.([]LawSpecValue)
			result := make([]T, len(values))
			for index, child := range values {
				result[index] = lsNativeContext(fmt.Sprintf("List[%d]", index), func() T {
					return element.toNative(child)
				})
			}
			return result
		},
		func(value []T, path lawSpecPath) LawSpecValue {
			defer path.enter(value)()
			result := make([]LawSpecValue, len(value))
			for index, child := range value {
				result[index] = lsSchemaContext(fmt.Sprintf("List[%d]", index), func() LawSpecValue {
					return element.encode(child, path)
				})
			}
			return LawSpecValue{typeRef.key(), result}
		}, symbols)
}

func lsMaybeCodec[T any](schema *lawSpecSchema, bits int, element lawSpecCodec[T], contexts ...map[string]*lawSpecSymbol) lawSpecCodec[LawSpecMaybe[T]] {
	symbols := lsSchemaSymbols(contexts)
	typeRef := lsNamed("Maybe", element.typeRef)
	return lsCodec(schema, bits, typeRef,
		func(value LawSpecValue) LawSpecMaybe[T] {
			data := value.Data.(lawSpecData)
			if data.tag == "Maybe::Nothing" {
				return LawSpecNothing[T]()
			}
			return LawSpecJust(element.toNative(data.fields[0]))
		},
		func(value LawSpecMaybe[T], path lawSpecPath) LawSpecValue {
			if !value.present {
				return schema.construct(typeRef, "Maybe::Nothing", nil, bits, symbols)
			}
			return schema.construct(typeRef, "Maybe::Just",
				[]LawSpecValue{element.encode(value.value, path)}, bits, symbols)
		}, symbols)
}

func lsEitherCodec[L, R any](schema *lawSpecSchema, bits int, left lawSpecCodec[L], right lawSpecCodec[R], contexts ...map[string]*lawSpecSymbol) lawSpecCodec[LawSpecEither[L, R]] {
	symbols := lsSchemaSymbols(contexts)
	typeRef := lsNamed("Either", left.typeRef, right.typeRef)
	return lsCodec(schema, bits, typeRef,
		func(value LawSpecValue) LawSpecEither[L, R] {
			data := value.Data.(lawSpecData)
			if data.tag == "Either::Left" {
				return LawSpecLeft[L, R](left.toNative(data.fields[0]))
			}
			return LawSpecRight[L, R](right.toNative(data.fields[0]))
		},
		func(value LawSpecEither[L, R], path lawSpecPath) LawSpecValue {
			switch value.tag {
			case 1:
				return schema.construct(typeRef, "Either::Left",
					[]LawSpecValue{left.encode(value.left, path)}, bits, symbols)
			case 2:
				return schema.construct(typeRef, "Either::Right",
					[]LawSpecValue{right.encode(value.right, path)}, bits, symbols)
			default:
				panic("Either requires Left or Right")
			}
		}, symbols)
}

func lsNullableCodec[T any](schema *lawSpecSchema, bits int, element lawSpecCodec[T], contexts ...map[string]*lawSpecSymbol) lawSpecCodec[LawSpecNullable[T]] {
	symbols := lsSchemaSymbols(contexts)
	typeRef := lsNamed("Nullable", element.typeRef)
	return lsCodec(schema, bits, typeRef,
		func(value LawSpecValue) LawSpecNullable[T] {
			presence := value.Data.(lawSpecPresence)
			if presence.value == nil {
				return LawSpecNullable[T]{}
			}
			return LawSpecNullable[T]{true, element.toNative(*presence.value)}
		},
		func(value LawSpecNullable[T], path lawSpecPath) LawSpecValue {
			if !value.Present {
				return lsPresent(typeRef.key(), nil)
			}
			child := element.encode(value.Value, path)
			return lsPresent(typeRef.key(), &child)
		}, symbols)
}

func lsOptionalCodec[T any](schema *lawSpecSchema, bits int, element lawSpecCodec[T], contexts ...map[string]*lawSpecSymbol) lawSpecCodec[LawSpecOptional[T]] {
	symbols := lsSchemaSymbols(contexts)
	typeRef := lsNamed("Optional", element.typeRef)
	return lsCodec(schema, bits, typeRef,
		func(value LawSpecValue) LawSpecOptional[T] {
			presence := value.Data.(lawSpecPresence)
			if presence.value == nil {
				return LawSpecOptional[T]{}
			}
			return LawSpecOptional[T]{true, element.toNative(*presence.value)}
		},
		func(value LawSpecOptional[T], path lawSpecPath) LawSpecValue {
			if !value.Present {
				return lsPresent(typeRef.key(), nil)
			}
			child := element.encode(value.Value, path)
			return lsPresent(typeRef.key(), &child)
		}, symbols)
}
