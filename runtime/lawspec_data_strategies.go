// Native Rapid combinators retain framework generation and shrinking.
package RUNTIME_PACKAGE

import (
	"flag"
	"fmt"
	"math/big"
	"slices"
	"strconv"
	"sync"

	"pgregory.net/rapid"
)

// Generated tests are sequential. Serialize scoped flag changes as well, and
// restore them before another generated check or a parallel user test can run.
var lawSpecRapidSettings sync.Mutex

func lsRapidCheck(t rapid.TB, cases int, property func(*rapid.T)) {
	t.Helper()
	if cases < 1 {
		t.Fatalf("property case count must be positive")
		return
	}
	lawSpecRapidSettings.Lock()
	defer lawSpecRapidSettings.Unlock()
	setting := flag.Lookup("rapid.checks")
	previous := setting.Value.String()
	defer func() { _ = setting.Value.Set(previous) }()
	if err := setting.Value.Set(strconv.Itoa(cases)); err != nil {
		t.Fatalf("configuring Rapid: %v", err)
		return
	}
	rapid.Check(t, property)
}

// Rapid 1.2.0 caps each native filter at five attempts. Smaller requested
// limits use native discards, preserving replay and invalid-shrink handling.
// The surrounding native generators and engine retain their own retry limits.
func lsBoundedFilter[T any](source *rapid.Generator[T], attempts int, predicate func(T) bool) *rapid.Generator[T] {
	if attempts < 1 {
		panic("filter attempt limit must be positive")
	}
	if attempts >= 5 {
		return source.Filter(predicate)
	}
	return rapid.Custom(func(t *rapid.T) T {
		draws := 0
		bounded := rapid.Custom(func(inner *rapid.T) T {
			if draws >= attempts {
				inner.SkipNow()
			}
			draws++
			return source.Draw(inner, "candidate")
		})
		return bounded.Filter(predicate).Draw(t, "accepted")
	})
}

type lawSpecGeneratorKey struct {
	typeName string
	budget   int
}

func lsDataStrategy(schema *lawSpecSchema, reference lawSpecTypeRef, bits, budget int,
	scalar func(string) *rapid.Generator[LawSpecValue]) *rapid.Generator[LawSpecValue] {
	if schema.hasContracts() {
		panic("constructor contracts require checked strategies")
	}
	return lsBuildDataStrategy(schema, reference, bits, budget, scalar, nil)
}

type lawSpecCheckedValue struct {
	value    LawSpecValue
	problem  any
	rejected bool
}

func (c lawSpecCheckedValue) requireValue() LawSpecValue {
	if c.problem != nil {
		panic(c.problem)
	}
	if c.rejected {
		panic("rejected constructor candidate escaped filtering")
	}
	return c.value
}

// Catch validation failures only. Never intercept Rapid's internal discard panics.
func lsCheckCandidate(schema *lawSpecSchema, reference lawSpecTypeRef, value LawSpecValue,
	bits int, symbols map[string]*lawSpecSymbol) (result lawSpecCheckedValue) {
	result.value = value
	defer func() {
		if problem := recover(); problem != nil {
			if _, rejected := problem.(lawSpecRefinementViolation); rejected {
				result.rejected = true
			} else {
				result.problem = problem
			}
		}
	}()
	result.value = schema.validate(reference, value, bits, symbols)
	return result
}

// Native factories compose Rapid generators rather than sampling into a new RNG.
type lawSpecNativeFactory func(*lawSpecSchema, lawSpecTypeRef, int,
	map[string]*lawSpecSymbol, []*rapid.Generator[LawSpecValue]) *rapid.Generator[LawSpecValue]

type lawSpecNativeGeneratorFailure struct {
	typeName string
	problem  any
}

func (e lawSpecNativeGeneratorFailure) Error() string {
	return fmt.Sprintf("native generator %s: %v", e.typeName, e.problem)
}

func lsNativeGeneratorConvert[T any](reference lawSpecTypeRef, convert func() T) (value T) {
	defer func() {
		if problem := recover(); problem != nil {
			panic(lawSpecNativeGeneratorFailure{reference.key(), problem})
		}
	}()
	return convert()
}

func lsNativeGeneratorValues[T any](codec lawSpecCodec[T], source *rapid.Generator[T]) *rapid.Generator[LawSpecValue] {
	return rapid.Map(source, func(value T) LawSpecValue {
		return lsNativeGeneratorConvert(codec.typeRef, func() LawSpecValue { return codec.fromNative(value) })
	})
}

func lsNativeGeneratorArguments[T any](codec lawSpecCodec[T], source *rapid.Generator[LawSpecValue]) *rapid.Generator[T] {
	return rapid.Map(source, func(value LawSpecValue) T {
		return lsNativeGeneratorConvert(codec.typeRef, func() T { return codec.toNative(value) })
	})
}

type lawSpecCheckedStrategy struct {
	factories map[string]lawSpecNativeFactory
	attempts  int
	problem   any
	symbols   map[string]*lawSpecSymbol
	witnesses map[string][]LawSpecValue
}

func lsDataNodes(value LawSpecValue) int {
	count := 1
	switch data := value.Data.(type) {
	case lawSpecData:
		for _, child := range data.fields {
			count += lsDataNodes(child)
		}
	case []LawSpecValue:
		for _, child := range data {
			count += lsDataNodes(child)
		}
	case lawSpecPresence:
		if data.value != nil {
			count += lsDataNodes(*data.value)
		}
	}
	return count
}

func (c *lawSpecCheckedStrategy) addWitness(schema *lawSpecSchema, reference lawSpecTypeRef,
	value LawSpecValue) {
	c.witnesses[reference.key()] = append(c.witnesses[reference.key()], value)
	switch data := value.Data.(type) {
	case []LawSpecValue:
		for _, child := range data {
			c.addWitness(schema, reference.arguments[0], child)
		}
	case lawSpecPresence:
		if data.value != nil {
			c.addWitness(schema, reference.arguments[0], *data.value)
		}
	case lawSpecData:
		constructors, custom := schema.constructors(reference)
		if custom {
			for _, constructor := range constructors {
				if constructor.tag == data.tag {
					for index, field := range constructor.fields {
						c.addWitness(schema, field.typeRef, data.fields[index])
					}
				}
			}
		} else if len(data.fields) != 0 {
			index := 0
			if data.tag == "Either::Right" {
				index = 1
			}
			c.addWitness(schema, reference.arguments[index], data.fields[0])
		}
	}
}

// Rapid's native Filter bounds retries and discards invalid replay candidates.
// Seed alternatives use native SampledFrom, preserving the framework's shrinker.
func lsCheckedDataStrategy(schema *lawSpecSchema, reference lawSpecTypeRef, bits, budget int,
	symbols map[string]*lawSpecSymbol, witnesses []LawSpecValue,
	scalar func(string) *rapid.Generator[LawSpecValue]) *rapid.Generator[lawSpecCheckedValue] {
	return lsCheckedDataStrategyWithAttempts(schema, reference, bits, budget, 5, symbols, witnesses, scalar)
}

func lsCheckedDataStrategyWithAttempts(schema *lawSpecSchema, reference lawSpecTypeRef, bits, budget, attempts int,
	symbols map[string]*lawSpecSymbol, witnesses []LawSpecValue,
	scalar func(string) *rapid.Generator[LawSpecValue], factories ...map[string]lawSpecNativeFactory) *rapid.Generator[lawSpecCheckedValue] {
	if attempts < 1 {
		panic("filter attempt limit must be positive")
	}
	context := &lawSpecCheckedStrategy{attempts: attempts, symbols: lsSchemaSymbols([]map[string]*lawSpecSymbol{symbols}),
		witnesses: map[string][]LawSpecValue{}}
	if len(factories) > 1 {
		panic("only one native factory registry is allowed")
	}
	if len(factories) == 1 {
		context.factories = factories[0]
	}
	for _, witness := range witnesses {
		context.addWitness(schema, reference, schema.validate(reference, witness, bits, context.symbols))
	}
	// Validate the plan now; every sample/replay gets its own error state.
	_ = lsBuildDataStrategy(schema, reference, bits, budget, scalar, context)
	return rapid.Custom(func(t *rapid.T) (result lawSpecCheckedValue) {
		defer func() {
			if problem := recover(); problem != nil {
				if _, native := problem.(lawSpecNativeGeneratorFailure); native {
					result = lawSpecCheckedValue{problem: problem}
				} else {
					panic(problem) // Rapid discards and replay control remain Rapid-owned.
				}
			}
		}()
		sample := *context
		raw := lsBuildDataStrategy(schema, reference, bits, budget, scalar, &sample)
		value := raw.Draw(t, "candidate")
		if sample.problem != nil {
			return lawSpecCheckedValue{problem: sample.problem}
		}
		return lsCheckCandidate(schema, reference, value, bits, sample.symbols)
	})
}

func lsBuildDataStrategy(schema *lawSpecSchema, reference lawSpecTypeRef, bits, budget int,
	scalar func(string) *rapid.Generator[LawSpecValue], checked *lawSpecCheckedStrategy) *rapid.Generator[LawSpecValue] {
	if budget < 1 {
		panic("structural node budget must be positive")
	}
	if bits != 32 && bits != 64 {
		panic("machineBits must be 32 or 64")
	}
	schema.check(reference, 0)
	construct := func(t lawSpecTypeRef, tag string, values []LawSpecValue, bits int) LawSpecValue {
		if checked != nil {
			return LawSpecValue{t.key(), lawSpecData{tag, values}}
		}
		return schema.construct(t, tag, values, bits)
	}
	minima := map[lawSpecGeneratorKey]int{}
	inhabitants := map[lawSpecGeneratorKey]bool{}
	arbitraries := map[lawSpecGeneratorKey]*rapid.Generator[LawSpecValue]{}
	var minimum func(lawSpecTypeRef, int) int
	var inhabited func(lawSpecTypeRef, int) bool
	var allocation func([]lawSpecFieldSchema, int) ([]int, bool)
	var build func(lawSpecTypeRef, int) *rapid.Generator[LawSpecValue]
	minimum = func(typeRef lawSpecTypeRef, limit int) int {
		key := lawSpecGeneratorKey{typeRef.key(), limit}
		if cost, exists := minima[key]; exists {
			return cost
		}
		for cost := 1; cost <= limit; cost++ {
			if inhabited(typeRef, cost) {
				minima[key] = cost
				return cost
			}
		}
		minima[key] = 0
		return 0
	}
	allocation = func(fields []lawSpecFieldSchema, available int) ([]int, bool) {
		costs := make([]int, len(fields))
		for index, field := range fields {
			cost := minimum(field.typeRef, available)
			if cost == 0 {
				return nil, false
			}
			costs[index] = cost
			available -= cost
		}
		for index := range costs {
			costs[index] += available / len(costs)
			if index < available%len(costs) {
				costs[index]++
			}
		}
		return costs, true
	}
	inhabited = func(typeRef lawSpecTypeRef, available int) bool {
		if available < 1 {
			return false
		}
		key := lawSpecGeneratorKey{typeRef.key(), available}
		if result, exists := inhabitants[key]; exists {
			return result
		}
		if checked != nil && checked.factories[typeRef.name] != nil {
			return true
		}
		constructors, custom := schema.constructors(typeRef)
		result := false
		if custom {
			for _, constructor := range constructors {
				if _, ok := allocation(constructor.fields, available-1); ok {
					result = true
					break
				}
			}
		} else {
			switch typeRef.name {
			case "List", "Maybe", "Nullable", "Optional":
				result = true
			case "Either":
				result = inhabited(typeRef.arguments[0], available-1) || inhabited(typeRef.arguments[1], available-1)
			default:
				result = len(typeRef.arguments) == 0
			}
		}
		inhabitants[key] = result
		return result
	}
	build = func(typeRef lawSpecTypeRef, available int) *rapid.Generator[LawSpecValue] {
		key := lawSpecGeneratorKey{typeRef.key(), available}
		if result, exists := arbitraries[key]; exists {
			return result
		}
		if !inhabited(typeRef, available) {
			panic(fmt.Sprintf("no value of %s within structural node budget %d", typeRef.key(), available))
		}
		if checked != nil && checked.factories[typeRef.name] != nil {
			arguments := make([]*rapid.Generator[LawSpecValue], len(typeRef.arguments))
			for i, argument := range typeRef.arguments {
				if inhabited(argument, available) {
					arguments[i] = build(argument, available)
				} else {
					// Phantom parameters may be empty. Rapid owns discards if
					// the native factory actually draws this argument.
					arguments[i] = rapid.Custom(func(t *rapid.T) LawSpecValue {
						t.Skipf("no native generator argument for %s within node budget %d", argument.key(), available)
						return LawSpecValue{} // Skipf does not return.
					})
				}
			}
			source := checked.factories[typeRef.name](schema, typeRef, bits, checked.symbols, arguments)
			result := rapid.Map(source, func(value LawSpecValue) LawSpecValue {
				return lsNativeGeneratorConvert(typeRef, func() LawSpecValue {
					return schema.validate(typeRef, value, bits, checked.symbols)
				})
			})
			arbitraries[key] = result
			return result // Custom distributions never use witness fallback or contract rejection.
		}
		constructors, custom := schema.constructors(typeRef)
		var result *rapid.Generator[LawSpecValue]
		if custom {
			alternatives := []*rapid.Generator[LawSpecValue]{}
			for _, constructor := range constructors {
				costs, ok := allocation(constructor.fields, available-1)
				if !ok {
					continue
				}
				if len(costs) == 0 {
					alternatives = append(alternatives, rapid.Just(construct(typeRef, constructor.tag, nil, bits)))
					continue
				}
				fields := make([]*rapid.Generator[LawSpecValue], len(costs))
				for index, field := range constructor.fields {
					fields[index] = build(field.typeRef, costs[index])
				}
				alternatives = append(alternatives, rapid.Custom(func(t *rapid.T) LawSpecValue {
					values := make([]LawSpecValue, len(fields))
					for index, field := range fields {
						values[index] = field.Draw(t, constructor.fields[index].name)
					}
					return construct(typeRef, constructor.tag, values, bits)
				}))
			}
			result = rapid.OneOf(alternatives...)
		} else if len(typeRef.arguments) == 0 {
			result = rapid.Map(scalar(typeRef.name), func(value LawSpecValue) LawSpecValue {
				if checked != nil {
					return value
				}
				return schema.validate(typeRef, value, bits)
			})
		} else {
			switch typeRef.name {
			case "List":
				remaining := available - 1
				cost := minimum(typeRef.arguments[0], remaining)
				maximum := 0
				if cost != 0 {
					maximum = remaining / cost
				}
				// Prebuild choices so draws never mutate the construction caches.
				lists := make([]*rapid.Generator[[]LawSpecValue], maximum+1)
				lists[0] = rapid.Just([]LawSpecValue{})
				for length := 1; length <= maximum; length++ {
					lists[length] = rapid.SliceOfN(build(typeRef.arguments[0], remaining/length), length, length)
				}
				result = rapid.Custom(func(t *rapid.T) LawSpecValue {
					length := rapid.IntRange(0, maximum).Draw(t, "length")
					return LawSpecValue{typeRef.key(), lists[length].Draw(t, "items")}
				})
			case "Maybe", "Nullable", "Optional":
				absent := lsPresent(typeRef.key(), nil)
				if typeRef.name == "Maybe" {
					absent = construct(typeRef, "Maybe::Nothing", nil, bits)
				}
				result = rapid.Just(absent)
				if inhabited(typeRef.arguments[0], available-1) {
					present := rapid.Map(build(typeRef.arguments[0], available-1), func(value LawSpecValue) LawSpecValue {
						if typeRef.name == "Maybe" {
							return construct(typeRef, "Maybe::Just", []LawSpecValue{value}, bits)
						}
						return lsPresent(typeRef.key(), &value)
					})
					result = rapid.OneOf(result, present)
				}
			case "Either":
				alternatives := []*rapid.Generator[LawSpecValue]{}
				for index, child := range typeRef.arguments {
					if inhabited(child, available-1) {
						tag := []string{"Either::Left", "Either::Right"}[index]
						alternatives = append(alternatives, rapid.Map(build(child, available-1), func(value LawSpecValue) LawSpecValue {
							return construct(typeRef, tag, []LawSpecValue{value}, bits)
						}))
					}
				}
				result = rapid.OneOf(alternatives...)
			default:
				panic("unsupported data generator: " + typeRef.name)
			}
		}
		if checked != nil {
			seeds := []LawSpecValue{}
			for _, witness := range checked.witnesses[typeRef.key()] {
				if lsDataNodes(witness) <= available {
					seeds = append(seeds, witness)
				}
			}
			if len(seeds) != 0 {
				result = rapid.OneOf(result, rapid.SampledFrom(seeds))
			}
			filtered := lsBoundedFilter(result, checked.attempts, func(value LawSpecValue) bool {
				if checked.problem != nil {
					return true
				}
				candidate := lsCheckCandidate(schema, typeRef, value, bits, checked.symbols)
				if candidate.problem != nil {
					checked.problem = candidate.problem
				}
				return !candidate.rejected
			})
			result = rapid.Custom(func(t *rapid.T) LawSpecValue {
				// Do not draw more fields after an evaluator failure.
				if checked.problem != nil {
					return rapid.Just(LawSpecValue{}).Draw(t, "failed")
				}
				return filtered.Draw(t, "checked")
			})
		}
		arbitraries[key] = result
		return result
	}
	return build(reference, budget)
}

// lsIndexedDataStrategy constructs values whose linear structural measure
// equals target. Each constructor's equation holds its constant followed by
// the positions of recursive fields whose measures it adds, so the target is
// solved backwards and split across those fields. Nothing is filtered away.
func lsIndexedDataStrategy(schema *lawSpecSchema, reference lawSpecTypeRef, bits, budget int,
	target LawSpecValue, equations map[string][]int64,
	scalar func(string) *rapid.Generator[LawSpecValue]) *rapid.Generator[lawSpecCheckedValue] {
	number, ok := target.Data.(*big.Int)
	if !ok || number.Sign() < 0 || !number.IsInt64() {
		panic("index target must be a natural number")
	}
	if _, custom := schema.constructors(reference); !custom {
		panic("indexed generation requires a data type")
	}
	plain := map[string]*rapid.Generator[LawSpecValue]{}
	plainField := func(typeRef lawSpecTypeRef) (generator *rapid.Generator[LawSpecValue]) {
		if cached, exists := plain[typeRef.key()]; exists {
			return cached
		}
		defer func() {
			if recover() != nil {
				generator = nil
			}
			plain[typeRef.key()] = generator
		}()
		return lsBuildDataStrategy(schema, typeRef, bits, budget, scalar, nil)
	}
	equation := func(tag string) (int64, []int) {
		found, exists := equations[tag]
		if !exists {
			panic("missing index equation for " + tag)
		}
		positions := make([]int, len(found)-1)
		for i, position := range found[1:] {
			positions[i] = int(position)
		}
		return found[0], positions
	}
	type request struct {
		key   string
		index int64
	}
	reachableMemo := map[request]bool{}
	visiting := map[request]bool{}
	var reachable func(lawSpecTypeRef, int64) bool
	var splittable func([]lawSpecTypeRef, int64) bool
	feasible := func(typeRef lawSpecTypeRef, constructor lawSpecConstructorSchema, k int64) ([]lawSpecTypeRef, bool) {
		constant, positions := equation(constructor.tag)
		rest := k - constant
		if rest < 0 {
			return nil, false
		}
		types := make([]lawSpecTypeRef, len(positions))
		for i, position := range positions {
			types[i] = constructor.fields[position].typeRef
		}
		for index, field := range constructor.fields {
			if !slices.Contains(positions, index) && plainField(field.typeRef) == nil {
				return nil, false
			}
		}
		if len(types) == 0 {
			return types, rest == 0
		}
		return types, splittable(types, rest)
	}
	reachable = func(typeRef lawSpecTypeRef, k int64) bool {
		key := request{typeRef.key(), k}
		if result, exists := reachableMemo[key]; exists {
			return result
		}
		if visiting[key] {
			return false
		}
		visiting[key] = true
		constructors, _ := schema.constructors(typeRef)
		result := false
		for _, constructor := range constructors {
			if _, ok := feasible(typeRef, constructor, k); ok {
				result = true
				break
			}
		}
		delete(visiting, key)
		reachableMemo[key] = result
		return result
	}
	splittable = func(types []lawSpecTypeRef, rest int64) bool {
		if len(types) == 1 {
			return reachable(types[0], rest)
		}
		for first := int64(0); first <= rest; first++ {
			if reachable(types[0], first) && splittable(types[1:], rest-first) {
				return true
			}
		}
		return false
	}
	var draw func(*rapid.T, lawSpecTypeRef, int64) LawSpecValue
	draw = func(t *rapid.T, typeRef lawSpecTypeRef, k int64) LawSpecValue {
		constructors, _ := schema.constructors(typeRef)
		options := []lawSpecConstructorSchema{}
		for _, constructor := range constructors {
			if _, ok := feasible(typeRef, constructor, k); ok {
				options = append(options, constructor)
			}
		}
		if len(options) == 0 {
			panic(fmt.Sprintf("no value of %s has index %d", typeRef.key(), k))
		}
		constructor := options[rapid.IntRange(0, len(options)-1).Draw(t, "constructor")]
		constant, positions := equation(constructor.tag)
		types, _ := feasible(typeRef, constructor, k)
		targets := make([]int64, len(types))
		rest := k - constant
		for i := range types {
			if i == len(types)-1 {
				targets[i] = rest
				break
			}
			choices := []int64{}
			for first := int64(0); first <= rest; first++ {
				if reachable(types[i], first) && splittable(types[i+1:], rest-first) {
					choices = append(choices, first)
				}
			}
			targets[i] = choices[rapid.IntRange(0, len(choices)-1).Draw(t, "split")]
			rest -= targets[i]
		}
		values := make([]LawSpecValue, len(constructor.fields))
		for index, field := range constructor.fields {
			if position := slices.Index(positions, index); position >= 0 {
				values[index] = draw(t, field.typeRef, targets[position])
			} else {
				values[index] = plainField(field.typeRef).Draw(t, field.name)
			}
		}
		return schema.construct(typeRef, constructor.tag, values, bits)
	}
	return rapid.Custom(func(t *rapid.T) lawSpecCheckedValue {
		return lawSpecCheckedValue{value: draw(t, reference, number.Int64())}
	})
}
