// Structural validation is independent of property-testing frameworks.
package RUNTIME_PACKAGE

import (
	"fmt"
	"reflect"
)

// Conversion paths reject cycles while allowing shared acyclic subtrees.
type lawSpecPathKey struct {
	typeOf  reflect.Type
	pointer uintptr
	length  int
}

type lawSpecPath map[lawSpecPathKey]bool

func (p lawSpecPath) enter(value any) func() {
	rv := reflect.ValueOf(value)
	if !rv.IsValid() || (rv.Kind() != reflect.Slice && rv.Kind() != reflect.Pointer) || rv.IsNil() {
		return func() {}
	}
	length := 0
	if rv.Kind() == reflect.Slice {
		length = rv.Len()
		if length == 0 {
			return func() {}
		}
	}
	key := lawSpecPathKey{rv.Type(), rv.Pointer(), length}
	if p[key] {
		panic("cyclic structural value")
	}
	p[key] = true
	return func() { delete(p, key) }
}

type lawSpecTypeRef struct {
	name      string
	arguments []lawSpecTypeRef
	parameter int
}

func lsNamed(name string, arguments ...lawSpecTypeRef) lawSpecTypeRef {
	return lawSpecTypeRef{name: name, arguments: arguments}
}

func lsParameter(index int) lawSpecTypeRef {
	return lawSpecTypeRef{parameter: index}
}

func (t lawSpecTypeRef) key() string {
	if t.name == "" {
		panic("uninstantiated schema parameter")
	}
	result := t.name
	for _, argument := range t.arguments {
		if len(t.arguments) == 1 {
			result += " " + argument.key()
		} else {
			result += " (" + argument.key() + ")"
		}
	}
	return result
}

type lawSpecFieldSchema struct {
	name    string
	typeRef lawSpecTypeRef
}

type lawSpecConstructorSchema struct {
	tag    string
	fields []lawSpecFieldSchema
}

type lawSpecDataSchema struct {
	name         string
	parameters   int
	constructors []lawSpecConstructorSchema
}

// Predicates run in declaration order after recursive representation validation.
type lawSpecFieldPredicate func(*lawSpecSchema, []lawSpecTypeRef, []LawSpecValue, int, map[string]*lawSpecSymbol) bool

type lawSpecConstructorContract struct {
	tag        string
	predicates []lawSpecFieldPredicate
}

type lawSpecRefinementViolation struct{ message string }

func (v lawSpecRefinementViolation) Error() string { return v.message }

type lawSpecSchema struct {
	definitions map[string]lawSpecDataSchema
	arity       map[string]int
	contracts   map[string][]lawSpecFieldPredicate
}

func lsNewSchema(definitions []lawSpecDataSchema, primitives []string) *lawSpecSchema {
	schema := &lawSpecSchema{definitions: map[string]lawSpecDataSchema{}, arity: map[string]int{
		"List": 1, "Maybe": 1, "Either": 2, "Nullable": 1, "Optional": 1,
	}}
	for _, name := range primitives {
		if _, exists := schema.arity[name]; exists || name == "" {
			panic("duplicate or invalid primitive: " + name)
		}
		schema.arity[name] = 0
	}
	for _, definition := range definitions {
		if _, exists := schema.arity[definition.name]; exists || definition.name == "" {
			panic("duplicate or invalid type: " + definition.name)
		}
		if definition.parameters < 0 {
			panic("negative parameter count: " + definition.name)
		}
		// Own the schema metadata; callers cannot mutate it after registration.
		constructors := make([]lawSpecConstructorSchema, len(definition.constructors))
		for index, constructor := range definition.constructors {
			fields := make([]lawSpecFieldSchema, len(constructor.fields))
			for position, field := range constructor.fields {
				fields[position] = lawSpecFieldSchema{field.name, lsCopyType(field.typeRef)}
			}
			constructors[index] = lawSpecConstructorSchema{constructor.tag, fields}
		}
		definition.constructors = constructors
		schema.definitions[definition.name] = definition
		schema.arity[definition.name] = definition.parameters
	}
	tags := map[string]bool{}
	for _, definition := range schema.definitions {
		for _, constructor := range definition.constructors {
			if constructor.tag == "" || tags[constructor.tag] {
				panic("duplicate or invalid constructor: " + constructor.tag)
			}
			tags[constructor.tag] = true
			names := map[string]bool{}
			for _, field := range constructor.fields {
				if field.name == "" || names[field.name] {
					panic("duplicate or invalid field: " + field.name)
				}
				names[field.name] = true
				schema.check(field.typeRef, definition.parameters)
			}
		}
	}
	return schema
}

// Keep contract metadata separate from the representation-only schema API.
func lsNewSchemaWithContracts(definitions []lawSpecDataSchema, primitives []string,
	contracts []lawSpecConstructorContract) *lawSpecSchema {
	schema := lsNewSchema(definitions, primitives)
	schema.contracts = map[string][]lawSpecFieldPredicate{}
	tags := map[string]bool{}
	for _, definition := range schema.definitions {
		for _, constructor := range definition.constructors {
			tags[constructor.tag] = true
		}
	}
	for _, contract := range contracts {
		if _, exists := schema.contracts[contract.tag]; exists || !tags[contract.tag] {
			panic("duplicate or unknown constructor contract: " + contract.tag)
		}
		predicates := append([]lawSpecFieldPredicate{}, contract.predicates...)
		for _, predicate := range predicates {
			if predicate == nil {
				panic("nil constructor predicate: " + contract.tag)
			}
		}
		schema.contracts[contract.tag] = predicates
	}
	return schema
}

func (s *lawSpecSchema) hasContracts() bool {
	for _, predicates := range s.contracts {
		if len(predicates) != 0 {
			return true
		}
	}
	return false
}

func lsSchemaSymbols(contexts []map[string]*lawSpecSymbol) map[string]*lawSpecSymbol {
	if len(contexts) > 1 {
		panic("expected at most one Symbol context")
	}
	if len(contexts) == 1 && contexts[0] != nil {
		return contexts[0]
	}
	return map[string]*lawSpecSymbol{}
}

// A false predicate is a rejected candidate; evaluator failures remain panics.
func (s *lawSpecSchema) accepts(t lawSpecTypeRef, value LawSpecValue, bits int,
	contexts ...map[string]*lawSpecSymbol) (accepted bool) {
	defer func() {
		if problem := recover(); problem != nil {
			if _, rejected := problem.(lawSpecRefinementViolation); rejected {
				accepted = false
			} else {
				panic(problem)
			}
		}
	}()
	s.validate(t, value, bits, contexts...)
	return true
}

func lsCopyType(t lawSpecTypeRef) lawSpecTypeRef {
	arguments := make([]lawSpecTypeRef, len(t.arguments))
	for index, argument := range t.arguments {
		arguments[index] = lsCopyType(argument)
	}
	t.arguments = arguments
	return t
}

func (s *lawSpecSchema) check(t lawSpecTypeRef, parameters int) {
	if t.name == "" {
		if t.parameter < 0 || t.parameter >= parameters || len(t.arguments) != 0 {
			panic("unbound schema parameter")
		}
		return
	}
	arity, exists := s.arity[t.name]
	if !exists || arity != len(t.arguments) {
		panic("unknown type or wrong arity: " + t.name)
	}
	for _, argument := range t.arguments {
		s.check(argument, parameters)
	}
}

func lsSubstitute(t lawSpecTypeRef, arguments []lawSpecTypeRef) lawSpecTypeRef {
	if t.name == "" {
		return lsCopyType(arguments[t.parameter])
	}
	children := make([]lawSpecTypeRef, len(t.arguments))
	for index, child := range t.arguments {
		children[index] = lsSubstitute(child, arguments)
	}
	return lsNamed(t.name, children...)
}

func (s *lawSpecSchema) constructors(t lawSpecTypeRef) ([]lawSpecConstructorSchema, bool) {
	s.check(t, 0)
	definition, exists := s.definitions[t.name]
	if !exists {
		return nil, false
	}
	result := make([]lawSpecConstructorSchema, len(definition.constructors))
	for index, constructor := range definition.constructors {
		fields := make([]lawSpecFieldSchema, len(constructor.fields))
		for position, field := range constructor.fields {
			fields[position] = lawSpecFieldSchema{field.name, lsSubstitute(field.typeRef, t.arguments)}
		}
		result[index] = lawSpecConstructorSchema{constructor.tag, fields}
	}
	return result, true
}

func lsSchemaContext(context string, operation func() LawSpecValue) (result LawSpecValue) {
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

// Payload recipes preserve declaration parameter identity through nested types.
// A nil plan ignores fixed fields, even when their concrete types match a slot.
type lawSpecPayloadPlan struct {
	name      string
	parameter int
	arguments []*lawSpecPayloadPlan
}

func lsPayloadRecipe(t lawSpecTypeRef, arguments []*lawSpecPayloadPlan) *lawSpecPayloadPlan {
	if t.name == "" {
		return arguments[t.parameter]
	}
	children := make([]*lawSpecPayloadPlan, len(t.arguments))
	stored := false
	for index, child := range t.arguments {
		children[index] = lsPayloadRecipe(child, arguments)
		stored = stored || children[index] != nil
	}
	if !stored {
		return nil
	}
	return &lawSpecPayloadPlan{name: t.name, arguments: children}
}

// Validate the whole value and its contracts before invoking scoped callbacks.
func (s *lawSpecSchema) allPayloads(t lawSpecTypeRef, value LawSpecValue,
	predicates []func(LawSpecValue) LawSpecValue, bits int,
	contexts ...map[string]*lawSpecSymbol) LawSpecValue {
	s.check(t, 0)
	if _, custom := s.definitions[t.name]; !custom {
		switch t.name {
		case "List", "Maybe", "Either", "Nullable", "Optional":
		default:
			panic("payload predicates require a data type")
		}
	}
	if len(predicates) != len(t.arguments) {
		panic("payload predicate arity mismatch")
	}
	predicates = append([]func(LawSpecValue) LawSpecValue{}, predicates...)
	arguments := make([]*lawSpecPayloadPlan, len(predicates))
	for index, predicate := range predicates {
		if predicate == nil {
			panic("nil payload predicate")
		}
		arguments[index] = &lawSpecPayloadPlan{parameter: index}
	}
	checked := s.validate(t, value, bits, contexts...)
	return lsBool(s.walkPayload(&lawSpecPayloadPlan{name: t.name, arguments: arguments}, checked, predicates))
}

func (s *lawSpecSchema) contextualPayload(plan *lawSpecPayloadPlan, value LawSpecValue,
	predicates []func(LawSpecValue) LawSpecValue, context string) bool {
	return lsTruth(lsSchemaContext(context, func() LawSpecValue {
		return lsBool(s.walkPayload(plan, value, predicates))
	}))
}

func (s *lawSpecSchema) walkPayload(plan *lawSpecPayloadPlan, value LawSpecValue,
	predicates []func(LawSpecValue) LawSpecValue) bool {
	if plan == nil {
		return true
	}
	if plan.name == "" {
		return lsTruth(predicates[plan.parameter](value))
	}
	arguments := plan.arguments
	switch plan.name {
	case "List":
		for index, child := range value.Data.([]LawSpecValue) {
			if !s.contextualPayload(arguments[0], child, predicates, fmt.Sprintf("List[%d]", index)) {
				return false
			}
		}
		return true
	case "Nullable", "Optional":
		presence := value.Data.(lawSpecPresence)
		return presence.value == nil || s.contextualPayload(arguments[0], *presence.value, predicates, plan.name+".value")
	}
	data := value.Data.(lawSpecData)
	switch plan.name {
	case "Maybe":
		return data.tag == "Maybe::Nothing" || s.contextualPayload(arguments[0], data.fields[0], predicates, "Maybe::Just.value")
	case "Either":
		index := 0
		if data.tag == "Either::Right" {
			index = 1
		}
		return s.contextualPayload(arguments[index], data.fields[0], predicates, data.tag+".value")
	}
	for _, constructor := range s.definitions[plan.name].constructors {
		if constructor.tag != data.tag {
			continue
		}
		for index, field := range constructor.fields {
			if !s.contextualPayload(lsPayloadRecipe(field.typeRef, arguments), data.fields[index], predicates, data.tag+"."+field.name) {
				return false
			}
		}
		return true
	}
	panic("invalid checked payload constructor")
}

func (s *lawSpecSchema) validate(t lawSpecTypeRef, value LawSpecValue, bits int, contexts ...map[string]*lawSpecSymbol) LawSpecValue {
	return s.validateValue(t, value, bits, lawSpecPath{}, lsSchemaSymbols(contexts))
}

func (s *lawSpecSchema) validateValue(t lawSpecTypeRef, value LawSpecValue, bits int, path lawSpecPath, symbols map[string]*lawSpecSymbol) LawSpecValue {
	var payload any
	switch data := value.Data.(type) {
	case lawSpecData:
		payload = data.fields
	case []LawSpecValue:
		payload = data
	case lawSpecPresence:
		payload = data.value
	}
	defer path.enter(payload)()
	s.check(t, 0)
	if bits != 32 && bits != 64 {
		panic("machineBits must be 32 or 64")
	}
	if value.Type != t.key() {
		panic("invalid representation for " + t.key())
	}
	constructors, custom := s.constructors(t)
	if !custom {
		switch t.name {
		case "List":
			values, ok := value.Data.([]LawSpecValue)
			if !ok {
				panic("List payload must be a slice of values")
			}
			result := make([]LawSpecValue, len(values))
			for index, child := range values {
				result[index] = lsSchemaContext(fmt.Sprintf("List[%d]", index), func() LawSpecValue {
					return s.validateValue(t.arguments[0], child, bits, path, symbols)
				})
			}
			return LawSpecValue{t.key(), result}
		case "Nullable", "Optional":
			presence, ok := value.Data.(lawSpecPresence)
			if !ok {
				panic("invalid presence representation")
			}
			if presence.value == nil {
				return value
			}
			child := s.validateValue(t.arguments[0], *presence.value, bits, path, symbols)
			return lsPresent(t.key(), &child)
		case "Maybe":
			constructors = []lawSpecConstructorSchema{
				{"Maybe::Nothing", nil},
				{"Maybe::Just", []lawSpecFieldSchema{{"value", t.arguments[0]}}},
			}
		case "Either":
			constructors = []lawSpecConstructorSchema{
				{"Either::Left", []lawSpecFieldSchema{{"value", t.arguments[0]}}},
				{"Either::Right", []lawSpecFieldSchema{{"value", t.arguments[1]}}},
			}
		default:
			return lsClone(lsValidate(t.name, value, bits))
		}
	}
	data, ok := value.Data.(lawSpecData)
	if !ok {
		panic("expected constructor payload for " + t.key())
	}
	for _, constructor := range constructors {
		if constructor.tag != data.tag {
			continue
		}
		if len(constructor.fields) != len(data.fields) {
			panic("wrong field count: " + data.tag)
		}
		fields := make([]LawSpecValue, len(data.fields))
		for index, field := range constructor.fields {
			fields[index] = lsSchemaContext(data.tag+"."+field.name, func() LawSpecValue {
				return s.validateValue(field.typeRef, data.fields[index], bits, path, symbols)
			})
		}
		for index, predicate := range s.contracts[data.tag] {
			lsSchemaContext(fmt.Sprintf("%s predicate %d", data.tag, index+1), func() LawSpecValue {
				if !predicate(s, t.arguments, fields, bits, symbols) {
					panic(lawSpecRefinementViolation{"constructor field contract rejected"})
				}
				return lsBool(true)
			})
		}
		return LawSpecValue{t.key(), lawSpecData{data.tag, fields}}
	}
	panic("unknown constructor " + data.tag + " for " + t.key())
}

func (s *lawSpecSchema) construct(t lawSpecTypeRef, tag string, fields []LawSpecValue, bits int, contexts ...map[string]*lawSpecSymbol) LawSpecValue {
	symbols := lsSchemaSymbols(contexts)
	if t.name == "List" {
		s.check(t, 0)
		switch tag {
		case "List::Nil":
			if len(fields) != 0 {
				panic("Nil takes no fields")
			}
			return s.validate(t, LawSpecValue{t.key(), []LawSpecValue{}}, bits, symbols)
		case "List::Cons":
			if len(fields) != 2 {
				panic("Cons takes two fields")
			}
			tail := s.validate(t, fields[1], bits, symbols).Data.([]LawSpecValue)
			return s.validate(t, LawSpecValue{t.key(), append([]LawSpecValue{fields[0]}, tail...)}, bits, symbols)
		default:
			panic("unknown List constructor: " + tag)
		}
	}
	return s.validate(t, LawSpecValue{t.key(), lawSpecData{tag, fields}}, bits, symbols)
}

func (s *lawSpecSchema) equal(t lawSpecTypeRef, a, b LawSpecValue, bits int, contexts ...map[string]*lawSpecSymbol) bool {
	symbols := lsSchemaSymbols(contexts)
	a, b = s.validate(t, a, bits, symbols), s.validate(t, b, bits, symbols)
	return lsSchemaEqual(a, b)
}

func lsSchemaEqual(a, b LawSpecValue) bool {
	if x, ok := a.Data.(lawSpecData); ok {
		y, ok := b.Data.(lawSpecData)
		if !ok || x.tag != y.tag || len(x.fields) != len(y.fields) {
			return false
		}
		for index, field := range x.fields {
			if !lsSchemaEqual(field, y.fields[index]) {
				return false
			}
		}
		return true
	}
	if x, ok := a.Data.([]LawSpecValue); ok {
		y, ok := b.Data.([]LawSpecValue)
		if !ok || len(x) != len(y) {
			return false
		}
		for index, field := range x {
			if !lsSchemaEqual(field, y[index]) {
				return false
			}
		}
		return true
	}
	if x, ok := a.Data.(lawSpecPresence); ok {
		y, ok := b.Data.(lawSpecPresence)
		if !ok || (x.value == nil) != (y.value == nil) {
			return false
		}
		return x.value == nil || lsSchemaEqual(*x.value, *y.value)
	}
	return lsEqual(a, b)
}

// Check the complete native binding, including fields in unselected variants.
func (s *lawSpecSchema) checkNativeProfile(t lawSpecTypeRef, bits int) {
	visited := map[string]bool{}
	var check func(lawSpecTypeRef)
	check = func(current lawSpecTypeRef) {
		for _, argument := range current.arguments {
			check(argument)
		}
		lsCheckNativeProfile(current.name, bits)
		if visited[current.name] {
			return
		}
		visited[current.name] = true
		constructors, _ := s.constructors(current)
		for _, constructor := range constructors {
			for _, field := range constructor.fields {
				check(field.typeRef)
			}
		}
	}
	check(t)
}
