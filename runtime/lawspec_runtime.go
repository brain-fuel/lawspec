// Portable scalar arithmetic. No test framework dependencies.
package RUNTIME_PACKAGE

import (
	"fmt"
	"math"
	"math/big"
	"math/rand"
	"os"
	"reflect"
	goruntime "runtime"
	"sort"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"time"
	"unicode/utf8"
)

type LawSpecValue struct {
	Type string
	Data any
}
type lawSpecDecimal struct {
	coefficient *big.Int
	exponent    int
}
type lawSpecSymbol struct {
	description string
	// A workflow runtime travels in the symbols map under lsWorkflowKey.
	workflow *LawSpecWorkflowRuntime
}
type lawSpecPresence struct{ value *LawSpecValue }

// lawSpecHandle is a handle's logical value: the adapter's native value,
// carried unopened. Two handles are equal only when they are the same native
// value; they have no portable order.
type lawSpecHandle struct{ native any }

// lsSameNative is identity: == for comparable values, the same backing
// pointer for maps, slices, functions and channels.
func lsSameNative(x, y any) bool {
	if x == nil || y == nil {
		return x == nil && y == nil
	}
	tx, ty := reflect.TypeOf(x), reflect.TypeOf(y)
	if tx != ty {
		return false
	}
	if tx.Comparable() {
		same := false
		func() {
			defer func() { _ = recover() }()
			same = x == y
		}()
		return same
	}
	vx, vy := reflect.ValueOf(x), reflect.ValueOf(y)
	switch vx.Kind() {
	case reflect.Map, reflect.Func, reflect.Chan, reflect.Pointer, reflect.UnsafePointer:
		return vx.Pointer() == vy.Pointer()
	case reflect.Slice:
		return vx.Pointer() == vy.Pointer() && vx.Len() == vy.Len()
	}
	return false
}

// Handle labels, numbered per type by first appearance in the process.
var (
	lsHandleLock   sync.Mutex
	lsHandleLabels = map[string][]lawSpecHandleLabel{}
)

type lawSpecHandleLabel struct {
	native any
	number int
}

// lsHandleLabel is a handle's stable label, such as Jobs#1.
func lsHandleLabel(typeName string, native any) string {
	segments := strings.Split(typeName, "::")
	name := segments[len(segments)-1]
	lsHandleLock.Lock()
	defer lsHandleLock.Unlock()
	labels := lsHandleLabels[typeName]
	for _, label := range labels {
		if lsSameNative(label.native, native) {
			return name + "#" + strconv.Itoa(label.number)
		}
	}
	number := len(labels) + 1
	lsHandleLabels[typeName] = append(labels, lawSpecHandleLabel{native, number})
	return name + "#" + strconv.Itoa(number)
}

// Named support types preserve scalar domains in native data fields.
type LawSpecDecimal = lawSpecDecimal
type LawSpecSymbol = lawSpecSymbol
type LawSpecUnit struct{}
type LawSpecNull struct{}
type LawSpecUndefined struct{}

// Presence is tagged so nested nullable and optional states remain distinct.
type LawSpecNullable[T any] struct {
	Present bool
	Value   T
}

type LawSpecOptional[T any] struct {
	Present bool
	Value   T
}

// LawSpecMaybe keeps algebraic absence separate from nullable payloads.
type LawSpecMaybe[T any] struct {
	present bool
	value   T
}

func LawSpecNothing[T any]() LawSpecMaybe[T]     { return LawSpecMaybe[T]{} }
func LawSpecJust[T any](value T) LawSpecMaybe[T] { return LawSpecMaybe[T]{true, value} }
func (m LawSpecMaybe[T]) Value() (T, bool)       { return m.value, m.present }
func (m LawSpecMaybe[T]) lawSpecTag() string {
	if m.present {
		return "Maybe::Just"
	}
	return "Maybe::Nothing"
}
func (m LawSpecMaybe[T]) lawSpecFields() []any {
	if m.present {
		return []any{m.value}
	}
	return nil
}

// LawSpecEither has an explicit constructor; its zero value is invalid.
type LawSpecEither[L, R any] struct {
	tag   uint8
	left  L
	right R
}

func LawSpecLeft[L, R any](value L) LawSpecEither[L, R] {
	return LawSpecEither[L, R]{tag: 1, left: value}
}
func LawSpecRight[L, R any](value R) LawSpecEither[L, R] {
	return LawSpecEither[L, R]{tag: 2, right: value}
}
func (e LawSpecEither[L, R]) Left() (L, bool)  { return e.left, e.tag == 1 }
func (e LawSpecEither[L, R]) Right() (R, bool) { return e.right, e.tag == 2 }
func (e LawSpecEither[L, R]) lawSpecTag() string {
	switch e.tag {
	case 1:
		return "Either::Left"
	case 2:
		return "Either::Right"
	default:
		panic("Either requires Left or Right")
	}
}
func (e LawSpecEither[L, R]) lawSpecFields() []any {
	switch e.tag {
	case 1:
		return []any{e.left}
	case 2:
		return []any{e.right}
	default:
		panic("Either requires Left or Right")
	}
}

type lawSpecSum interface {
	lawSpecTag() string
	lawSpecFields() []any
}
type lawSpecData struct {
	tag    string
	fields []LawSpecValue
}

func (d lawSpecData) String() string { return fmt.Sprintf("%s(%v)", d.tag, d.fields) }

func lsSumType(t string) bool {
	return strings.HasPrefix(t, "Maybe ") || strings.HasPrefix(t, "Either ")
}
func lsEitherArguments(t string) []string {
	if !strings.HasPrefix(t, "Either ") {
		panic("Either type required")
	}
	var result []string
	for cursor := 7; cursor < len(t); {
		if t[cursor] != '(' {
			panic("invalid Either type: " + t)
		}
		cursor++
		start, depth := cursor, 1
		for cursor < len(t) && depth > 0 {
			if t[cursor] == '(' {
				depth++
			}
			if t[cursor] == ')' {
				depth--
			}
			cursor++
		}
		if depth != 0 || cursor == start+1 {
			panic("invalid Either type: " + t)
		}
		result = append(result, t[start:cursor-1])
		if cursor < len(t) {
			if t[cursor] != ' ' || cursor+1 == len(t) {
				panic("invalid Either type: " + t)
			}
			cursor++
		}
	}
	if len(result) != 2 {
		panic("Either requires two type arguments")
	}
	return result
}
func lsSumFields(t, tag string) []string {
	if strings.HasPrefix(t, "Maybe ") {
		switch tag {
		case "Maybe::Nothing":
			return nil
		case "Maybe::Just":
			return []string{strings.TrimPrefix(t, "Maybe ")}
		}
	}
	if strings.HasPrefix(t, "Either ") {
		arguments := lsEitherArguments(t)
		switch tag {
		case "Either::Left":
			return arguments[:1]
		case "Either::Right":
			return arguments[1:]
		}
	}
	panic("invalid constructor " + tag + " for " + t)
}
func lsDataValue(value LawSpecValue) lawSpecData {
	data, ok := value.Data.(lawSpecData)
	if !ok || len(lsSumFields(value.Type, data.tag)) != len(data.fields) {
		panic("invalid sum representation")
	}
	return data
}
func lsMaybeToNative[T any](t string, value LawSpecValue, bits int, element func(LawSpecValue) T) LawSpecMaybe[T] {
	if !strings.HasPrefix(t, "Maybe ") {
		panic("Maybe type required")
	}
	lsCheckNativeProfile(t, bits)
	data := lsDataValue(lsConvert(t, value, bits))
	if data.tag == "Maybe::Nothing" {
		return LawSpecNothing[T]()
	}
	return LawSpecJust(element(data.fields[0]))
}
func lsEitherToNative[L, R any](t string, value LawSpecValue, bits int, left func(LawSpecValue) L, right func(LawSpecValue) R) LawSpecEither[L, R] {
	if !strings.HasPrefix(t, "Either ") {
		panic("Either type required")
	}
	lsCheckNativeProfile(t, bits)
	data := lsDataValue(lsConvert(t, value, bits))
	if data.tag == "Either::Left" {
		return LawSpecLeft[L, R](left(data.fields[0]))
	}
	return LawSpecRight[L, R](right(data.fields[0]))
}
func lsAllElements(value LawSpecValue, predicate func(LawSpecValue) LawSpecValue) LawSpecValue {
	values, ok := value.Data.([]LawSpecValue)
	if !ok {
		panic("expected List in element predicate")
	}
	index := 0
	defer func() {
		if failure := recover(); failure != nil {
			panic(fmt.Sprintf("List element %d: %v", index, failure))
		}
	}()
	for index = range values {
		if !lsTruth(predicate(values[index])) {
			return lsBool(false)
		}
	}
	return lsBool(true)
}

func lsMatchMaybe(value LawSpecValue, nothing func() LawSpecValue, just func(LawSpecValue) LawSpecValue) LawSpecValue {
	data := lsDataValue(value)
	switch data.tag {
	case "Maybe::Nothing":
		return nothing()
	case "Maybe::Just":
		return just(data.fields[0])
	default:
		panic("Maybe value required")
	}
}
func lsMatchEither(value LawSpecValue, left, right func(LawSpecValue) LawSpecValue) LawSpecValue {
	data := lsDataValue(value)
	switch data.tag {
	case "Either::Left":
		return left(data.fields[0])
	case "Either::Right":
		return right(data.fields[0])
	default:
		panic("Either value required")
	}
}

func lsList(t string, values []LawSpecValue) LawSpecValue {
	return LawSpecValue{t, append([]LawSpecValue{}, values...)}
}

func lsConstruct(t, tag string, fields []LawSpecValue) LawSpecValue {
	if lsSumType(t) {
		if len(lsSumFields(t, tag)) != len(fields) {
			panic("invalid constructor arity: " + tag)
		}
		return LawSpecValue{t, lawSpecData{tag, append([]LawSpecValue{}, fields...)}}
	}
	switch tag {
	case "List::Nil":
		if len(fields) == 0 {
			return lsList(t, nil)
		}
	case "List::Cons":
		if len(fields) == 2 {
			if tail, ok := fields[1].Data.([]LawSpecValue); ok {
				return lsList(t, append([]LawSpecValue{fields[0]}, tail...))
			}
		}
	}
	panic("invalid constructor or arity: " + tag)
}

func lsSignedInteger(t string, value int64) LawSpecValue {
	return lsInteger(t, strconv.FormatInt(value, 10))
}

func lsUnsignedInteger(t string, value uint64) LawSpecValue {
	return lsInteger(t, strconv.FormatUint(value, 10))
}

func lsListToNative[T any](t string, value LawSpecValue, bits int, element func(LawSpecValue) T) []T {
	lsCheckNativeProfile(t, bits)
	values := lsConvert(t, value, bits).Data.([]LawSpecValue)
	result := make([]T, len(values))
	for index, item := range values {
		result[index] = element(item)
	}
	return result
}

func lsCheckNativeProfile(t string, bits int) {
	if strings.HasPrefix(t, "List ") || strings.HasPrefix(t, "Maybe ") {
		lsCheckNativeProfile(strings.SplitN(t, " ", 2)[1], bits)
		return
	}
	if strings.HasPrefix(t, "Either ") {
		for _, argument := range lsEitherArguments(t) {
			lsCheckNativeProfile(argument, bits)
		}
		return
	}
	if (t == "IntSize" || t == "UIntSize" || t == "UIntPtr") && strconv.IntSize != bits {
		panic("machineBits does not match native architecture")
	}
}

func lsIntegerType(t string) bool {
	return strings.HasPrefix(t, "Int") || strings.HasPrefix(t, "UInt") || t == "BigInt" || t == "BigUInt"
}
func lsExactType(t string) bool { return lsIntegerType(t) || t == "Decimal" || t == "Rational" }
func lsInt(s string) *big.Int {
	n, ok := new(big.Int).SetString(s, 10)
	if !ok {
		panic("invalid integer")
	}
	return n
}
func lsInteger(t, n string) LawSpecValue { return LawSpecValue{t, lsInt(n)} }
func lsBool(b bool) LawSpecValue         { return LawSpecValue{"Bool", b} }
func lsDecimal(c, e string) LawSpecValue {
	n, err := strconv.Atoi(e)
	if err != nil {
		panic(err)
	}
	return LawSpecValue{"Decimal", lawSpecDecimal{lsInt(c), n}}
}
func lsRational(n, d string) LawSpecValue {
	return LawSpecValue{"Rational", new(big.Rat).SetFrac(lsInt(n), lsInt(d))}
}
func lsFloating(t, b string) LawSpecValue {
	n, err := strconv.ParseUint(b, 16, 64)
	if err != nil {
		panic(err)
	}
	v := math.Float64frombits(n)
	if t == "Float32" {
		v = float64(math.Float32frombits(uint32(n)))
	}
	return LawSpecValue{t, v}
}
func lsComplex(t string, r, i LawSpecValue) LawSpecValue {
	return LawSpecValue{t, complex(r.Data.(float64), i.Data.(float64))}
}
func lsSequence(t string, u []int) LawSpecValue        { return LawSpecValue{t, append([]int{}, u...)} }
func lsCharacter(t string, c int) LawSpecValue         { return LawSpecValue{t, c} }
func lsAbsent(t string) LawSpecValue                   { return LawSpecValue{t, nil} }
func lsPresent(t string, v *LawSpecValue) LawSpecValue { return LawSpecValue{t, lawSpecPresence{v}} }
func lsPointer(v LawSpecValue) *LawSpecValue           { return &v }
func lsSymbol(id, d string, symbols map[string]*lawSpecSymbol) LawSpecValue {
	s, ok := symbols[id]
	if !ok {
		s = &lawSpecSymbol{description: d}
		symbols[id] = s
	}
	return LawSpecValue{"Symbol", s}
}
func lsPow(n int) *big.Int { return new(big.Int).Exp(big.NewInt(10), big.NewInt(int64(n)), nil) }
func lsRatio(v LawSpecValue) *big.Rat {
	switch x := v.Data.(type) {
	case *big.Int:
		return new(big.Rat).SetInt(x)
	case *big.Rat:
		return new(big.Rat).Set(x)
	case lawSpecDecimal:
		if x.exponent >= 0 {
			return new(big.Rat).SetInt(new(big.Int).Mul(x.coefficient, lsPow(x.exponent)))
		}
		return new(big.Rat).SetFrac(x.coefficient, lsPow(-x.exponent))
	case float64:
		r := new(big.Rat).SetFloat64(x)
		if r == nil {
			panic("non-finite exact conversion")
		}
		return r
	default:
		panic("exact numeric value required")
	}
}
func lsReal(v LawSpecValue) float64 {
	if x, ok := v.Data.(float64); ok {
		return x
	}
	r, _ := lsRatio(v).Float64()
	return r
}
func lsPrecision(t string, x float64) float64 {
	if t == "Float32" || t == "Complex64" {
		return float64(float32(x))
	}
	return x
}
func lsConvert(t string, v LawSpecValue, bits int) LawSpecValue {
	if lsSumType(t) {
		data := lsDataValue(v)
		types := lsSumFields(t, data.tag)
		fields := make([]LawSpecValue, len(types))
		for index, fieldType := range types {
			fields[index] = lsConvert(fieldType, data.fields[index], bits)
		}
		return lsConstruct(t, data.tag, fields)
	}
	if strings.HasPrefix(t, "List ") {
		values, ok := v.Data.([]LawSpecValue)
		if !ok || !strings.HasPrefix(v.Type, "List ") {
			panic("List required")
		}
		converted := make([]LawSpecValue, len(values))
		for index, value := range values {
			converted[index] = lsConvert(strings.TrimPrefix(t, "List "), value, bits)
		}
		return lsList(t, converted)
	}
	if strings.HasPrefix(t, "Nullable ") || strings.HasPrefix(t, "Optional ") {
		parts := strings.SplitN(t, " ", 2)
		missing := "Null"
		if parts[0] == "Optional" {
			missing = "Undefined"
		}
		if v.Type == missing {
			return LawSpecValue{t, lawSpecPresence{nil}}
		}
		p, ok := v.Data.(lawSpecPresence)
		if !ok {
			panic("tagged presence required")
		}
		if p.value == nil {
			return LawSpecValue{t, p}
		}
		x := lsConvert(parts[1], *p.value, bits)
		return LawSpecValue{t, lawSpecPresence{&x}}
	}
	if lsIntegerType(t) {
		r := lsRatio(v)
		if !r.IsInt() {
			panic("fractional conversion to " + t)
		}
		n := new(big.Int).Set(r.Num())
		if t != "BigInt" && t != "Integer" {
			unsigned := strings.HasPrefix(t, "U") || t == "BigUInt"
			if unsigned && n.Sign() < 0 {
				panic("integer outside " + t + " range")
			}
			if t != "BigUInt" {
				w := bits
				if t != "IntSize" && t != "UIntSize" && t != "UIntPtr" {
					i := 3
					if unsigned {
						i = 4
					}
					var err error
					w, err = strconv.Atoi(t[i:])
					if err != nil {
						panic(err)
					}
				}
				p := w
				if !unsigned {
					p--
				}
				limit := new(big.Int).Lsh(big.NewInt(1), uint(p))
				lo := new(big.Int)
				if !unsigned {
					lo.Neg(limit)
				}
				hi := new(big.Int).Sub(limit, big.NewInt(1))
				if n.Cmp(lo) < 0 || n.Cmp(hi) > 0 {
					panic("integer outside " + t + " range")
				}
			}
		}
		return LawSpecValue{t, n}
	}
	if t == "Rational" {
		return LawSpecValue{t, lsRatio(v)}
	}
	if t == "Decimal" {
		r := lsRatio(v)
		d := new(big.Int).Set(r.Denom())
		a, b := 0, 0
		rem := new(big.Int)
		for rem.Mod(d, big.NewInt(2)).Sign() == 0 {
			d.Div(d, big.NewInt(2))
			a++
		}
		for rem.Mod(d, big.NewInt(5)).Sign() == 0 {
			d.Div(d, big.NewInt(5))
			b++
		}
		if d.Cmp(big.NewInt(1)) != 0 {
			panic("Decimal conversion is not finite; use round")
		}
		scale := max(a, b)
		c := new(big.Int).Set(r.Num())
		c.Mul(c, new(big.Int).Exp(big.NewInt(2), big.NewInt(int64(scale-a)), nil))
		c.Mul(c, new(big.Int).Exp(big.NewInt(5), big.NewInt(int64(scale-b)), nil))
		return LawSpecValue{t, lawSpecDecimal{c, -scale}}
	}
	if strings.HasPrefix(t, "Float") {
		if t == "Float32" && lsExactType(v.Type) {
			x, _ := lsRatio(v).Float32()
			return LawSpecValue{t, float64(x)}
		}
		return LawSpecValue{t, lsPrecision(t, lsReal(v))}
	}
	if strings.HasPrefix(t, "Complex") {
		z, ok := v.Data.(complex128)
		if !ok {
			component := "Float64"
			if t == "Complex64" {
				component = "Float32"
			}
			z = complex(lsConvert(component, v, bits).Data.(float64), 0)
		}
		return LawSpecValue{t, complex(lsPrecision(t, real(z)), lsPrecision(t, imag(z)))}
	}
	if t != v.Type {
		panic("cannot convert " + v.Type + " to " + t)
	}
	return lsValidate(t, v, bits)
}
func lsValidUnit(t string, c int) bool {
	hi := 1114111
	if t == "Bytes" {
		hi = 255
	}
	if t == "Utf16Text" || t == "CodeUnit16" {
		hi = 65535
	}
	return c >= 0 && c <= hi && (!(t == "Text" || t == "Char") || c < 55296 || c > 57343)
}
func lsValidate(t string, v LawSpecValue, bits int) LawSpecValue {
	if t != v.Type {
		panic("invalid " + t + " representation")
	}
	if lsSumType(t) {
		data := lsDataValue(v)
		for index, fieldType := range lsSumFields(t, data.tag) {
			lsValidate(fieldType, data.fields[index], bits)
		}
		return lsClone(v)
	}
	if strings.HasPrefix(t, "List ") {
		values, ok := v.Data.([]LawSpecValue)
		if !ok {
			panic("List required")
		}
		for _, value := range values {
			lsValidate(strings.TrimPrefix(t, "List "), value, bits)
		}
		return lsClone(v)
	}
	if lsIntegerType(t) {
		return lsConvert(t, v, bits)
	}
	valid := false
	if strings.HasPrefix(t, "Nullable ") || strings.HasPrefix(t, "Optional ") {
		x, ok := v.Data.(lawSpecPresence)
		valid = ok
		if ok && x.value != nil {
			lsValidate(strings.SplitN(t, " ", 2)[1], *x.value, bits)
		}
	} else {
		switch t {
		case "Text", "CodePointText", "Utf16Text", "Bytes":
			x, ok := v.Data.([]int)
			valid = ok
			if ok {
				for _, c := range x {
					if !lsValidUnit(t, c) {
						valid = false
					}
				}
			}
		case "Char", "CodePoint", "CodeUnit16":
			x, ok := v.Data.(int)
			valid = ok && lsValidUnit(t, x)
		case "Bool":
			_, valid = v.Data.(bool)
		case "Decimal":
			x, ok := v.Data.(lawSpecDecimal)
			valid = ok && x.coefficient != nil
		case "Rational":
			x, ok := v.Data.(*big.Rat)
			valid = ok && x != nil
		case "Float32", "Float64":
			x, ok := v.Data.(float64)
			valid = ok && (t == "Float64" || math.IsNaN(x) || float64(float32(x)) == x)
		case "Complex64", "Complex128":
			x, ok := v.Data.(complex128)
			valid = ok
			if ok && t == "Complex64" {
				lsValidate("Float32", LawSpecValue{"Float32", real(x)}, bits)
				lsValidate("Float32", LawSpecValue{"Float32", imag(x)}, bits)
			}
		case "Symbol":
			x, ok := v.Data.(*lawSpecSymbol)
			valid = ok && x != nil
		case "Unit", "Null", "Undefined":
			valid = v.Data == nil
		}
	}
	if !valid {
		panic("invalid " + t + " representation")
	}
	return v
}
func lsPromote(a, b, op string) string {
	if lsExactType(a) != lsExactType(b) {
		panic("exact/inexact mixing requires explicit conversion")
	}
	if lsExactType(a) {
		if op == "/" || a == "Rational" || b == "Rational" {
			return "Rational"
		}
		if a == "Decimal" || b == "Decimal" {
			return "Decimal"
		}
		return "Integer"
	}
	if strings.HasPrefix(a, "Complex") || strings.HasPrefix(b, "Complex") {
		if a == "Float64" || b == "Float64" || a == "Complex128" || b == "Complex128" {
			return "Complex128"
		}
		return "Complex64"
	}
	if a == "Float64" || b == "Float64" {
		return "Float64"
	}
	return "Float32"
}
func lsComparison(op string, c int) bool {
	switch op {
	case "==":
		return c == 0
	case "!=":
		return c != 0
	case "<":
		return c < 0
	case "<=":
		return c <= 0
	case ">":
		return c > 0
	case ">=":
		return c >= 0
	}
	panic("unknown comparison")
}
func lsBinary(op string, a, b LawSpecValue) LawSpecValue {
	if (op == "==" || op == "!=") && !lsExactType(a.Type) && !strings.HasPrefix(a.Type, "Float") && !strings.HasPrefix(a.Type, "Complex") {
		return lsBool((op == "==") == lsEqual(a, b))
	}
	t := lsPromote(a.Type, b.Type, op)
	comparison := strings.Contains(" == != < <= > >= ", " "+op+" ")
	if lsExactType(a.Type) {
		x, y := lsRatio(a), lsRatio(b)
		if comparison {
			return lsBool(lsComparison(op, x.Cmp(y)))
		}
		r := new(big.Rat)
		switch op {
		case "+":
			r.Add(x, y)
		case "-":
			r.Sub(x, y)
		case "*":
			r.Mul(x, y)
		case "/":
			r.Quo(x, y)
		case "pow":
			if !x.IsInt() || !y.IsInt() {
				panic("integer operands required")
			}
			if y.Num().Sign() < 0 {
				panic("negative exponent")
			}
			return LawSpecValue{"Integer", new(big.Int).Exp(x.Num(), y.Num(), nil)}
		case "quot", "rem":
			if !x.IsInt() || !y.IsInt() {
				panic("integer operands required")
			}
			q := new(big.Int)
			if op == "quot" {
				q.Quo(x.Num(), y.Num())
			} else {
				q.Rem(x.Num(), y.Num())
			}
			return LawSpecValue{"Integer", q}
		default:
			panic("unknown operator")
		}
		return lsConvert(t, LawSpecValue{"Rational", r}, 64)
	}
	if strings.HasPrefix(t, "Complex") {
		x, y := lsConvert(t, a, 64).Data.(complex128), lsConvert(t, b, 64).Data.(complex128)
		ar, ai, br, bi := real(x), imag(x), real(y), imag(y)
		rnd := func(x float64) float64 { return lsPrecision(t, x) }
		var re, im float64
		switch op {
		case "==":
			return lsBool(x == y)
		case "!=":
			return lsBool(x != y)
		case "+":
			re, im = ar+br, ai+bi
		case "-":
			re, im = ar-br, ai-bi
		case "*":
			re, im = rnd(ar*br)-rnd(ai*bi), rnd(ar*bi)+rnd(ai*br)
		case "/":
			d := rnd(rnd(br*br) + rnd(bi*bi))
			re, im = rnd(rnd(ar*br)+rnd(ai*bi))/d, rnd(rnd(ai*br)-rnd(ar*bi))/d
		default:
			panic("complex values are not ordered")
		}
		return LawSpecValue{t, complex(rnd(re), rnd(im))}
	}
	x, y := lsReal(a), lsReal(b)
	if comparison {
		switch op {
		case "==":
			return lsBool(x == y)
		case "!=":
			return lsBool(x != y)
		case "<":
			return lsBool(x < y)
		case "<=":
			return lsBool(x <= y)
		case ">":
			return lsBool(x > y)
		case ">=":
			return lsBool(x >= y)
		}
	}
	var v float64
	switch op {
	case "+":
		v = x + y
	case "-":
		v = x - y
	case "*":
		v = x * y
	case "/":
		v = x / y
	default:
		panic("unknown operator")
	}
	return LawSpecValue{t, lsPrecision(t, v)}
}
func lsEqual(a, b LawSpecValue) bool {
	if lsSumType(a.Type) || lsSumType(b.Type) {
		if !lsSumType(a.Type) || !lsSumType(b.Type) {
			return false
		}
		x, y := lsDataValue(a), lsDataValue(b)
		if x.tag != y.tag || len(x.fields) != len(y.fields) {
			return false
		}
		for index, field := range x.fields {
			if !lsEqual(field, y.fields[index]) {
				return false
			}
		}
		return true
	}
	if strings.HasPrefix(a.Type, "List ") && strings.HasPrefix(b.Type, "List ") {
		xs, ys := a.Data.([]LawSpecValue), b.Data.([]LawSpecValue)
		if len(xs) != len(ys) {
			return false
		}
		for index, value := range xs {
			if !lsEqual(value, ys[index]) {
				return false
			}
		}
		return true
	}
	if (strings.HasPrefix(a.Type, "Float") || strings.HasPrefix(a.Type, "Complex")) && (strings.HasPrefix(b.Type, "Float") || strings.HasPrefix(b.Type, "Complex")) {
		return lsTruth(lsBinary("==", a, b))
	}
	if lsExactType(a.Type) && lsExactType(b.Type) {
		return lsRatio(a).Cmp(lsRatio(b)) == 0
	}
	if a.Type != b.Type {
		return false
	}
	switch x := a.Data.(type) {
	case float64:
		return x == b.Data.(float64)
	case complex128:
		return x == b.Data.(complex128)
	case *lawSpecSymbol:
		return x == b.Data.(*lawSpecSymbol)
	case lawSpecHandle:
		y, ok := b.Data.(lawSpecHandle)
		return ok && lsSameNative(x.native, y.native)
	case lawSpecPresence:
		y := b.Data.(lawSpecPresence)
		if x.value == nil || y.value == nil {
			return x.value == nil && y.value == nil
		}
		return lsEqual(*x.value, *y.value)
	}
	return reflect.DeepEqual(a.Data, b.Data)
}
func lsTruth(v LawSpecValue) bool { return lsValidate("Bool", v, 64).Data.(bool) }
// LawSpecTask is an async adapter's result: a goroutine's value, awaited where
// it is used. A panic in the goroutine is raised again by Await.
type LawSpecTask[T any] struct{ state *lawSpecTaskState[T] }

type lawSpecTaskState[T any] struct {
	done    chan struct{}
	value   T
	failure any
}

// LawSpecGo starts work in a goroutine.
func LawSpecGo[T any](work func() T) LawSpecTask[T] {
	state := &lawSpecTaskState[T]{done: make(chan struct{})}
	go func() {
		defer close(state.done)
		defer func() { state.failure = recover() }()
		state.value = work()
	}()
	return LawSpecTask[T]{state}
}

// Await blocks until the task is done and returns its value.
func (t LawSpecTask[T]) Await() T {
	<-t.state.done
	if t.state.failure != nil {
		panic(t.state.failure)
	}
	return t.state.value
}

const lsOrdering = "lawspec.collections::type::Ordering"

// lsCompareValues is the portable total order: -1, 0 or 1. Exact numbers by
// value, sequences by unit, false before true, absence before presence,
// lists element by element, Nothing before Just, and other data by
// constructor identity, then fields left to right.
func lsCompareValues(a, b LawSpecValue) int {
	switch x := a.Data.(type) {
	case bool:
		y := b.Data.(bool)
		if x == y {
			return 0
		} else if x {
			return 1
		}
		return -1
	case *big.Int, *big.Rat, lawSpecDecimal:
		return lsRatio(a).Cmp(lsRatio(b))
	case int:
		return lsSign(x - b.Data.(int))
	case []int:
		y := b.Data.([]int)
		for i := 0; i < len(x) && i < len(y); i++ {
			if x[i] != y[i] {
				return lsSign(x[i] - y[i])
			}
		}
		return lsSign(len(x) - len(y))
	case []LawSpecValue:
		y := b.Data.([]LawSpecValue)
		for i := 0; i < len(x) && i < len(y); i++ {
			if order := lsCompareValues(x[i], y[i]); order != 0 {
				return order
			}
		}
		return lsSign(len(x) - len(y))
	case lawSpecPresence:
		y := b.Data.(lawSpecPresence)
		switch {
		case x.value == nil && y.value == nil:
			return 0
		case x.value == nil:
			return -1
		case y.value == nil:
			return 1
		}
		return lsCompareValues(*x.value, *y.value)
	case lawSpecData:
		y := b.Data.(lawSpecData)
		if x.tag != y.tag {
			if x.tag == "Maybe::Nothing" && y.tag == "Maybe::Just" {
				return -1
			}
			if x.tag == "Maybe::Just" && y.tag == "Maybe::Nothing" {
				return 1
			}
			return strings.Compare(x.tag, y.tag)
		}
		return lsCompareValues(LawSpecValue{"", x.fields}, LawSpecValue{"", y.fields})
	case lawSpecHandle:
		if y, ok := b.Data.(lawSpecHandle); ok && lsSameNative(x.native, y.native) {
			return 0
		}
		panic("handles have no portable order: " + a.Type)
	case nil:
		return 0
	}
	panic("values have no portable order: " + a.Type)
}

func lsSign(n int) int {
	switch {
	case n < 0:
		return -1
	case n > 0:
		return 1
	}
	return 0
}

func lsHelper(n string, args []LawSpecValue, bits int) LawSpecValue {
	switch n {
	case "checked":
		return lsBool(true)
	case "select":
		if lsTruth(args[0]) {
			return args[1]
		}
		return args[2]
	case "compare":
		tag := [...]string{"Less", "Equal", "Greater"}[lsCompareValues(args[0], args[1])+1]
		return LawSpecValue{lsOrdering, lawSpecData{lsOrdering + "::" + tag, nil}}
	case "length":
		if values, ok := args[0].Data.([]LawSpecValue); ok {
			return lsInteger("Integer", strconv.Itoa(len(values)))
		}
		return lsInteger("Integer", strconv.Itoa(len(args[0].Data.([]int))))
	case "isPresent":
		return lsBool(args[0].Data.(lawSpecPresence).value != nil)
	case "presentValue":
		p := args[0].Data.(lawSpecPresence).value
		if p == nil {
			panic("absent presence value")
		}
		return *p
	}

	x := args[0]
	switch n {
	case "real", "imag":
		z := x.Data.(complex128)
		f := real(z)
		if n == "imag" {
			f = imag(z)
		}
		t := "Float64"
		if x.Type == "Complex64" {
			t = "Float32"
		}
		return LawSpecValue{t, f}
	case "quot", "rem", "pow":
		return lsBinary(n, x, args[1])
	case "negate":
		if lsExactType(x.Type) {
			return lsBinary("-", lsInteger("BigInt", "0"), x)
		}
		if z, ok := x.Data.(complex128); ok {
			return LawSpecValue{x.Type, -z}
		}
		return LawSpecValue{x.Type, -lsReal(x)}
	case "isNaN":
		return lsBool(math.IsNaN(lsReal(x)))
	case "isInfinite":
		return lsBool(math.IsInf(lsReal(x), 0))
	case "isFinite":
		return lsBool(!math.IsInf(lsReal(x), 0) && !math.IsNaN(lsReal(x)))
	case "isNegativeZero":
		return lsBool(lsReal(x) == 0 && math.Signbit(lsReal(x)))
	case "round":
		scale := int(lsConvert("Int32", args[1], bits).Data.(*big.Int).Int64())
		r := lsRatio(x)
		factor := new(big.Rat)
		if scale >= 0 {
			factor.SetInt(lsPow(scale))
		} else {
			factor.SetFrac(big.NewInt(1), lsPow(-scale))
		}
		r.Mul(r, factor)
		q, rem := new(big.Int), new(big.Int)
		q.QuoRem(r.Num(), r.Denom(), rem)
		cmp := new(big.Int).Lsh(new(big.Int).Abs(rem), 1).Cmp(r.Denom())
		if cmp > 0 || (cmp == 0 && q.Bit(0) == 1) {
			q.Add(q, big.NewInt(int64(r.Sign())))
		}
		return lsConvert("Decimal", LawSpecValue{"Rational", new(big.Rat).Quo(new(big.Rat).SetInt(q), factor)}, bits)
	}
	return lsConvert(n, x, bits)
}
func (v LawSpecValue) String() string { return fmt.Sprintf("%s(%v)", v.Type, v.Data) }

func lsSample(t string, seed int, bits int) LawSpecValue {
	r := rand.New(rand.NewSource(int64(seed)))
	if strings.HasPrefix(t, "Nullable ") || strings.HasPrefix(t, "Optional ") {
		parts := strings.SplitN(t, " ", 2)
		if r.Intn(2) == 0 {
			return LawSpecValue{t, lawSpecPresence{nil}}
		}
		x := lsSample(parts[1], int(r.Int31()), bits)
		return LawSpecValue{t, lawSpecPresence{&x}}
	}
	if lsIntegerType(t) {
		w := 256
		if t != "BigInt" && t != "Integer" && t != "BigUInt" {
			w = bits
			if t != "IntSize" && t != "UIntSize" && t != "UIntPtr" {
				i := 3
				if strings.HasPrefix(t, "U") {
					i = 4
				}
				w, _ = strconv.Atoi(t[i:])
			}
		}
		limit := new(big.Int).Lsh(big.NewInt(1), uint(w))
		n := new(big.Int).Rand(r, limit)
		if (strings.HasPrefix(t, "Int") || t == "BigInt") && n.Bit(w-1) == 1 {
			n.Sub(n, limit)
		}
		return LawSpecValue{t, n}
	}
	switch t {
	case "Bool":
		return lsBool(r.Intn(2) == 0)
	case "Decimal":
		return LawSpecValue{t, lawSpecDecimal{lsSample("BigInt", int(r.Int31()), bits).Data.(*big.Int), r.Intn(41) - 20}}
	case "Rational":
		return LawSpecValue{t, new(big.Rat).SetFrac(lsSample("BigInt", int(r.Int31()), bits).Data.(*big.Int), new(big.Int).Add(lsSample("BigUInt", int(r.Int31()), bits).Data.(*big.Int), big.NewInt(1)))}
	case "Float32":
		return LawSpecValue{t, float64(math.Float32frombits(r.Uint32()))}
	case "Float64":
		return LawSpecValue{t, math.Float64frombits(r.Uint64())}
	case "Complex64", "Complex128":
		component := "Float64"
		if t == "Complex64" {
			component = "Float32"
		}
		return lsComplex(t, lsSample(component, int(r.Int31()), bits), lsSample(component, int(r.Int31()), bits))
	case "Symbol":
		return LawSpecValue{t, &lawSpecSymbol{description: "same"}}
	case "Unit", "Null", "Undefined":
		return lsAbsent(t)
	}
	max := 1114112
	if t == "Bytes" {
		max = 256
	}
	if t == "CodeUnit16" || t == "Utf16Text" {
		max = 65536
	}
	unit := func() int {
		for {
			c := r.Intn(max)
			if lsValidUnit(t, c) {
				return c
			}
		}
	}
	if t == "Char" || t == "CodePoint" || t == "CodeUnit16" {
		return lsCharacter(t, unit())
	}
	xs := make([]int, r.Intn(40))
	for i := range xs {
		xs[i] = unit()
	}
	return lsSequence(t, xs)
}

type LawSpecBigInt = big.Int
type LawSpecRational = big.Rat

func lsToNative(t string, v LawSpecValue, bits int) any {
	v = lsConvert(t, v, bits)
	lsCheckNativeProfile(t, bits)
	if lsIntegerType(t) {
		n := v.Data.(*big.Int)
		switch t {
		case "Int8":
			return int8(n.Int64())
		case "Int16":
			return int16(n.Int64())
		case "Int32":
			return int32(n.Int64())
		case "Int64":
			return n.Int64()
		case "UInt8":
			return uint8(n.Uint64())
		case "UInt16":
			return uint16(n.Uint64())
		case "UInt32":
			return uint32(n.Uint64())
		case "UInt64":
			return n.Uint64()
		case "IntSize":
			return int(n.Int64())
		case "UIntSize":
			return uint(n.Uint64())
		case "UIntPtr":
			return uintptr(n.Uint64())
		default:
			return new(big.Int).Set(n)
		}
	}
	if t == "Char" || t == "CodePoint" {
		return rune(v.Data.(int))
	}
	if t == "CodeUnit16" {
		return uint16(v.Data.(int))
	}
	if t == "Bytes" {
		xs := v.Data.([]int)
		out := make([]byte, len(xs))
		for i, c := range xs {
			out[i] = byte(c)
		}
		return out
	}
	if t == "Utf16Text" {
		xs := v.Data.([]int)
		out := make([]uint16, len(xs))
		for i, c := range xs {
			out[i] = uint16(c)
		}
		return out
	}
	if t == "CodePointText" {
		xs := v.Data.([]int)
		out := make([]rune, len(xs))
		for i, c := range xs {
			out[i] = rune(c)
		}
		return out
	}
	if t == "Text" {
		u := v.Data.([]int)
		r := make([]rune, len(u))
		for i, c := range u {
			r[i] = rune(c)
		}
		return string(r)
	}
	if t == "Rational" {
		return lsRatio(v)
	}
	if t == "Float32" {
		return float32(v.Data.(float64))
	}
	if t == "Complex64" {
		return complex64(v.Data.(complex128))
	}
	return v.Data
}
func lsFromNative(t string, value any, bits int) LawSpecValue {
	if v, ok := value.(LawSpecValue); ok {
		return lsClone(lsValidate(t, v, bits))
	}
	if lsSumType(t) {
		lsCheckNativeProfile(t, bits)
		native, ok := value.(lawSpecSum)
		if !ok {
			panic("native sum requires a constructor")
		}
		tag := native.lawSpecTag()
		types, values := lsSumFields(t, tag), native.lawSpecFields()
		if len(types) != len(values) {
			panic("invalid native constructor arity")
		}
		fields := make([]LawSpecValue, len(types))
		for index, fieldType := range types {
			fields[index] = lsFromNative(fieldType, values[index], bits)
		}
		return lsConstruct(t, tag, fields)
	}
	if strings.HasPrefix(t, "List ") {
		lsCheckNativeProfile(t, bits)
		values := reflect.ValueOf(value)
		if !values.IsValid() || values.Kind() != reflect.Slice {
			panic("native List requires a slice")
		}
		converted := make([]LawSpecValue, values.Len())
		for index := range converted {
			converted[index] = lsFromNative(strings.TrimPrefix(t, "List "), values.Index(index).Interface(), bits)
		}
		return lsList(t, converted)
	}
	lsCheckNativeProfile(t, bits)
	var data any = value
	if lsIntegerType(t) {
		rv := reflect.ValueOf(value)
		switch rv.Kind() {
		case reflect.Int, reflect.Int8, reflect.Int16, reflect.Int32, reflect.Int64:
			data = big.NewInt(rv.Int())
		case reflect.Uint, reflect.Uint8, reflect.Uint16, reflect.Uint32, reflect.Uint64, reflect.Uintptr:
			data = new(big.Int).SetUint64(rv.Uint())
		default:
			switch n := value.(type) {
			case *big.Int:
				if n == nil {
					panic("invalid Integer representation")
				}
				data = new(big.Int).Set(n)
			case big.Int:
				data = new(big.Int).Set(&n)
			default:
				panic("invalid Integer representation")
			}
		}
	}
	if t == "Char" || t == "CodePoint" {
		data = int(value.(rune))
	}
	if t == "CodeUnit16" {
		data = int(value.(uint16))
	}
	if t == "Bytes" {
		xs := value.([]byte)
		out := make([]int, len(xs))
		for i, c := range xs {
			out[i] = int(c)
		}
		data = out
	}
	if t == "Utf16Text" {
		xs := value.([]uint16)
		out := make([]int, len(xs))
		for i, c := range xs {
			out[i] = int(c)
		}
		data = out
	}
	if t == "CodePointText" {
		xs := value.([]rune)
		out := make([]int, len(xs))
		for i, c := range xs {
			out[i] = int(c)
		}
		data = out
	}
	if t == "Text" {
		text := value.(string)
		if !utf8.ValidString(text) {
			panic("Text cannot contain invalid UTF-8 bytes")
		}
		u := []int{}
		for _, c := range text {
			u = append(u, int(c))
		}
		data = u
	}
	if t == "Float32" {
		data = float64(value.(float32))
	}
	if t == "Complex64" {
		data = complex128(value.(complex64))
	}
	return lsClone(lsValidate(t, LawSpecValue{t, data}, bits))
}

func lsClone(v LawSpecValue) LawSpecValue {
	switch x := v.Data.(type) {
	case lawSpecData:
		fields := make([]LawSpecValue, len(x.fields))
		for index, field := range x.fields {
			fields[index] = lsClone(field)
		}
		v.Data = lawSpecData{x.tag, fields}
	case []LawSpecValue:
		values := make([]LawSpecValue, len(x))
		for index, value := range x {
			values[index] = lsClone(value)
		}
		v.Data = values
	case *big.Int:
		v.Data = new(big.Int).Set(x)
	case *big.Rat:
		v.Data = new(big.Rat).Set(x)
	case []int:
		v.Data = append([]int{}, x...)
	case lawSpecDecimal:
		v.Data = lawSpecDecimal{new(big.Int).Set(x.coefficient), x.exponent}
	case lawSpecPresence:
		if x.value != nil {
			c := lsClone(*x.value)
			v.Data = lawSpecPresence{&c}
		}
	}
	return v
}

type lawSpecBound struct {
	op    string
	value LawSpecValue
}
type lawSpecDomain struct {
	candidates func([]LawSpecValue, int) []LawSpecValue
	accept     func([]LawSpecValue) bool
}

func lsFloor(r *big.Rat) *big.Int {
	q, rem := new(big.Int).QuoRem(r.Num(), r.Denom(), new(big.Int))
	if rem.Sign() < 0 {
		q.Sub(q, big.NewInt(1))
	}
	return q
}
func lsCeil(r *big.Rat) *big.Int { return new(big.Int).Neg(lsFloor(new(big.Rat).Neg(r))) }
func lsDomainCandidates(t string, seed, bits int, restrictions []lawSpecBound, hints []LawSpecValue) []LawSpecValue {
	values := []LawSpecValue{}
	for _, hint := range hints {
		func() { defer func() { recover() }(); values = append(values, lsConvert(t, hint, bits)) }()
	}
	if lsIntegerType(t) {
		var lo, hi *big.Int
		if t == "BigUInt" {
			lo = big.NewInt(0)
		} else if t != "Integer" && t != "BigInt" {
			w := bits
			if t != "IntSize" && t != "UIntSize" && t != "UIntPtr" {
				w, _ = strconv.Atoi(strings.TrimLeft(t, "UInt"))
			}
			if strings.HasPrefix(t, "Int") {
				hi = new(big.Int).Lsh(big.NewInt(1), uint(w-1))
				lo = new(big.Int).Neg(new(big.Int).Set(hi))
				hi.Sub(hi, big.NewInt(1))
			} else {
				lo = big.NewInt(0)
				hi = new(big.Int).Sub(new(big.Int).Lsh(big.NewInt(1), uint(w)), big.NewInt(1))
			}
		}
		for _, b := range restrictions {
			r := lsRatio(b.value)
			if b.op == ">" || b.op == ">=" || b.op == "==" {
				v := lsCeil(r)
				if b.op == ">" {
					v.Add(lsFloor(r), big.NewInt(1))
				}
				if lo == nil || v.Cmp(lo) > 0 {
					lo = v
				}
			}
			if b.op == "<" || b.op == "<=" || b.op == "==" {
				v := lsFloor(r)
				if b.op == "<" {
					v.Sub(lsCeil(r), big.NewInt(1))
				}
				if hi == nil || v.Cmp(hi) < 0 {
					hi = v
				}
			}
		}
		if lo != nil && hi != nil && lo.Cmp(hi) > 0 {
			return nil
		}
		lower, upper := lo, hi
		if lower == nil {
			lower = new(big.Int).Neg(new(big.Int).Lsh(big.NewInt(1), 256))
			if hi != nil && hi.Sign() < 0 {
				lower.Add(lower, hi)
			}
		}
		if upper == nil {
			upper = new(big.Int).Lsh(big.NewInt(1), 256)
			if lo != nil && lo.Sign() > 0 {
				upper.Add(upper, lo)
			}
		}
		ns := []*big.Int{lower, upper, big.NewInt(0), big.NewInt(1), big.NewInt(-1), new(big.Int).Add(lower, big.NewInt(1)), new(big.Int).Sub(upper, big.NewInt(1))}
		random := rand.New(rand.NewSource(int64(seed)))
		width := new(big.Int).Add(new(big.Int).Sub(upper, lower), big.NewInt(1))
		for j := 0; j < 8; j++ {
			ns = append(ns, new(big.Int).Add(lower, new(big.Int).Rand(random, width)))
		}
		for _, n := range ns {
			values = append(values, LawSpecValue{t, n})
		}
		filtered := []LawSpecValue{}
		for _, v := range values {
			if lsIntegerType(v.Type) {
				n := v.Data.(*big.Int)
				if n.Cmp(lower) >= 0 && n.Cmp(upper) <= 0 {
					filtered = append(filtered, lsConvert(t, v, bits))
				}
			}
		}
		values = filtered
	} else {
		for j := 0; j < 8; j++ {
			values = append(values, lsSample(t, seed+j*7919, bits))
		}
	}
	if len(values) > 0 {
		offset := ((seed % len(values)) + len(values)) % len(values)
		values = append(append([]LawSpecValue{}, values[offset:]...), values[:offset]...)
	}
	return values
}
func lsGenerateTuple(domains []lawSpecDomain, seed, attempts int, prefix []LawSpecValue) ([]LawSpecValue, bool) {
	used := 0
	lastPrefix := prefix
	var search func([]LawSpecValue) ([]LawSpecValue, bool)
	search = func(values []LawSpecValue) ([]LawSpecValue, bool) {
		lastPrefix = values
		if len(values) == len(domains) {
			return values, true
		}
		if used >= attempts {
			return nil, false
		}
		used++
		d := domains[len(values)]
		for _, v := range d.candidates(values, seed+used*7919) {
			if used >= attempts {
				break
			}
			used++
			next := append(append([]LawSpecValue{}, values...), v)
			if d.accept(next) {
				if result, ok := search(next); ok {
					return result, true
				}
			}
		}
		return nil, false
	}
	for used < attempts {
		if result, ok := search(append([]LawSpecValue{}, prefix...)); ok {
			return result, true
		}
	}
	return lastPrefix, false
}
func lsRequireContract(condition bool, context string) {
	if !condition {
		panic(context)
	}
}
func lsContract(context string, condition bool, result LawSpecValue) LawSpecValue {
	lsRequireContract(condition, context)
	return result
}
func lsCapture(check func([]LawSpecValue), values []LawSpecValue) (failure any) {
	defer func() { failure = recover() }()
	check(values)
	return nil
}
func lsRefinedCase(domains []lawSpecDomain, seed, attempts, shrinks int, check func([]LawSpecValue), context string) {
	values, ok := lsGenerateTuple(domains, seed, attempts, nil)
	if !ok {
		panic(fmt.Sprintf("%s: refinement-generation-exhausted after %d attempts; prefix=%v; seed=%d", context, attempts, values, seed))
	}
	if original := lsCapture(check, values); original != nil {
		best, budget := values, shrinks
		for i := range best {
			value := best[i]
			candidates := domains[i].candidates(best[:i], 0)
			if lsIntegerType(value.Type) {
				initial := value.Data.(*big.Int)
				candidates = append([]LawSpecValue{{value.Type, big.NewInt(0)}, {value.Type, big.NewInt(int64(initial.Sign()))}}, candidates...)
				for n := new(big.Int).Quo(initial, big.NewInt(2)); new(big.Int).Abs(n).Cmp(big.NewInt(1)) > 0; n = new(big.Int).Quo(n, big.NewInt(2)) {
					candidates = append(candidates, LawSpecValue{value.Type, n})
				}
			}
			for _, candidate := range candidates {
				if budget <= 0 {
					break
				}
				budget--
				if lsComplexity(candidate).Cmp(lsComplexity(best[i])) >= 0 {
					continue
				}
				prefix := append(append([]LawSpecValue{}, best[:i]...), candidate)
				if !domains[i].accept(prefix) {
					continue
				}
				trial, ok := lsGenerateTuple(domains, seed, min(attempts, 100), prefix)
				if ok && lsCapture(check, trial) != nil {
					best = trial
				}
			}
		}
		panic(fmt.Sprintf("%s: %v; refined counterexample=%v; seed=%d", context, original, best, seed))
	}
}
func lsAssert(context string, actual, expected func() LawSpecValue) {
	defer func() {
		if err := recover(); err != nil {
			panic(fmt.Sprintf("%s: %v", context, err))
		}
	}()
	a, b := actual(), expected()
	if !lsEqual(a, b) {
		panic(fmt.Sprintf("%s | actual=%v expected=%v", context, a, b))
	}
}

func lsComplexity(v LawSpecValue) *big.Int {
	switch x := v.Data.(type) {
	case *big.Int:
		return new(big.Int).Abs(x)
	case []int:
		return big.NewInt(int64(len(x)))
	case lawSpecPresence:
		if x.value == nil {
			return big.NewInt(0)
		}
		return new(big.Int).Add(big.NewInt(1), lsComplexity(*x.value))
	case bool:
		if x {
			return big.NewInt(1)
		}
		return big.NewInt(0)
	case float64:
		return new(big.Int).SetUint64(math.Float64bits(math.Abs(x)))
	case complex128:
		return new(big.Int).Add(lsComplexity(LawSpecValue{"Float64", real(x)}), lsComplexity(LawSpecValue{"Float64", imag(x)}))
	case int:
		return big.NewInt(int64(x))
	}
	if lsExactType(v.Type) {
		r := lsRatio(v)
		return new(big.Int).Sub(new(big.Int).Add(new(big.Int).Abs(r.Num()), r.Denom()), big.NewInt(1))
	}
	if v.Data == nil {
		return big.NewInt(0)
	}
	return big.NewInt(1)
}

// Workflow runtime. A workflow runs under a runtime: a clock, a seeded
// random source, a trace of what happened, and the state of stateful stages.
// The runtime travels in the symbols map every generated function takes;
// without one, the default runtime applies (real time, unless the tests
// installed a virtual clock). Durations are int64 microseconds.

const lsWorkflowKey = "\x00lawspec.workflow"

// LawSpecClock tells the time and waits, in microseconds.
type LawSpecClock interface {
	Now() int64
	Sleep(micros int64)
}

// LawSpecRealClock is monotonic wall time.
type LawSpecRealClock struct{ start time.Time }

func (c *LawSpecRealClock) Now() int64        { return time.Since(c.start).Microseconds() }
func (c *LawSpecRealClock) Sleep(micros int64) { time.Sleep(time.Duration(micros) * time.Microsecond) }

// LawSpecVirtualClock advances when slept on and returns at once.
type LawSpecVirtualClock struct{ Time int64 }

func (c *LawSpecVirtualClock) Now() int64        { return c.Time }
func (c *LawSpecVirtualClock) Sleep(micros int64) { c.Time += micros }

// LawSpecSplitMix64 gives the same sequence on every target for a seed.
type LawSpecSplitMix64 struct{ state uint64 }

func (r *LawSpecSplitMix64) Next() uint64 {
	r.state += 0x9E3779B97F4A7C15
	z := r.state
	z = (z ^ (z >> 30)) * 0xBF58476D1CE4E5B9
	z = (z ^ (z >> 27)) * 0x94D049BB133111EB
	return z ^ (z >> 31)
}

// Below is uniform in [0, bound); 0 when bound is 0.
func (r *LawSpecSplitMix64) Below(bound uint64) uint64 {
	if bound == 0 {
		return 0
	}
	return r.Next() % bound
}

// LawSpecTraceEvent records a stage starting or finishing an attempt, or a wait.
type LawSpecTraceEvent struct {
	Kind, Stage string
	Number      int64
	Succeeded   bool
}

// LawSpecWorkflowRuntime is what a workflow runs under. Gates says whether
// rate limits, breakers, bulkheads and caches apply; the runtime generated
// tests install has them off, since a workflow law calls the workflow and
// its composition, which would see each other's state.
type LawSpecWorkflowRuntime struct {
	Clock  LawSpecClock
	Random LawSpecSplitMix64
	Trace  []LawSpecTraceEvent
	State  map[string]any
	Gates  bool
	// A frame per running workflow: the undos of its completed stages.
	frames [][]lawSpecUndo
	// When the running attempt of a stage with a timeout must end, or zero.
	deadline time.Time
	// The running attempt's hedge, or nil.
	hedge *lawSpecHedge
}

// lawSpecHedge: when an attempt has not succeeded after Delay microseconds,
// another starts beside it, up to Most in all; the first success wins.
type lawSpecHedge struct {
	Stage       string
	Delay, Most int64
}

// lawSpecTimedOut is raised by lsAwaitStep when an attempt outlives its
// stage's timeout, and recovered by the stage.
type lawSpecTimedOut struct{}

// lsAwaitStep is an asynchronous step's logical result: start begins the
// step and convert turns its native result into a logical value. The step
// runs within its stage's timeout and hedge, if any.
func lsAwaitStep[T any](symbols map[string]*lawSpecSymbol, start func() LawSpecTask[T], convert func(T) LawSpecValue) LawSpecValue {
	runtime := lsWorkflowRuntime(symbols)
	deadline, hedge := runtime.deadline, runtime.hedge
	if deadline.IsZero() && hedge == nil {
		return convert(start().Await())
	}
	var expiry <-chan time.Time
	if !deadline.IsZero() {
		timer := time.NewTimer(time.Until(deadline))
		defer timer.Stop()
		expiry = timer.C
	}
	most, delay := int64(1), time.Duration(0)
	if hedge != nil {
		most, delay = hedge.Most, time.Duration(hedge.Delay)*time.Microsecond
	}
	results := make(chan *lawSpecTaskState[T], most)
	started, pending := int64(0), 0
	var next <-chan time.Time
	var nextTimer *time.Timer
	defer func() {
		if nextTimer != nil {
			nextTimer.Stop()
		}
	}()
	launch := func() {
		started++
		pending++
		if started > 1 {
			runtime.Trace = append(runtime.Trace, LawSpecTraceEvent{"hedge", hedge.Stage, started, true})
		}
		task := start()
		go func() {
			<-task.state.done
			results <- task.state
		}()
		if nextTimer != nil {
			nextTimer.Stop()
		}
		next = nil
		if started < most {
			nextTimer = time.NewTimer(delay)
			next = nextTimer.C
		}
	}
	launch()
	for {
		select {
		case state := <-results:
			pending--
			if state.failure != nil {
				panic(state.failure)
			}
			value := convert(state.value)
			if data, ok := value.Data.(lawSpecData); !ok || data.tag != "Either::Left" || (pending == 0 && started >= most) {
				return value
			}
			if pending == 0 {
				launch()
			}
		case <-next:
			launch()
		case <-expiry:
			panic(lawSpecTimedOut{})
		}
	}
}

// lsScoped runs an attempt under its stage's timeout (failing with TimedOut
// when it outlives it) and hedge. Under the runtime generated tests install
// (gates off), both are off.
func lsScoped(runtime *LawSpecWorkflowRuntime, policy lawSpecStagePolicy, attempt func() LawSpecValue) (result LawSpecValue) {
	if !runtime.Gates || (policy.Timeout <= 0 && policy.Hedge == nil) {
		return attempt()
	}
	outerDeadline, outerHedge := runtime.deadline, runtime.hedge
	if policy.Timeout > 0 {
		runtime.deadline = time.Now().Add(time.Duration(policy.Timeout) * time.Microsecond)
	}
	if policy.Hedge != nil {
		hedge := *policy.Hedge
		hedge.Stage = policy.Stage
		runtime.hedge = &hedge
	}
	defer func() {
		runtime.deadline, runtime.hedge = outerDeadline, outerHedge
		if failure := recover(); failure != nil {
			if _, ok := failure.(lawSpecTimedOut); !ok {
				panic(failure)
			}
			if policy.Fail != nil {
				result = policy.Fail("TimedOut")
			} else {
				result = lsStageFailureValue("TimedOut")
			}
		}
	}()
	return attempt()
}

type lawSpecUndo struct {
	stage string
	undo  func()
}

// lsRunWorkflow runs a workflow whose stages compensate: when it fails, the
// undos of its completed stages run, last first.
func lsRunWorkflow(symbols map[string]*lawSpecSymbol, attempt func() LawSpecValue) LawSpecValue {
	runtime := lsWorkflowRuntime(symbols)
	runtime.frames = append(runtime.frames, nil)
	depth := len(runtime.frames)
	var frame []lawSpecUndo
	result := func() LawSpecValue {
		// The frame is taken back even when the workflow panics.
		defer func() {
			frame = runtime.frames[depth-1]
			runtime.frames = runtime.frames[:depth-1]
		}()
		return attempt()
	}()
	if data, ok := result.Data.(lawSpecData); ok && data.tag == "Either::Left" {
		for i := len(frame) - 1; i >= 0; i-- {
			runtime.Trace = append(runtime.Trace, LawSpecTraceEvent{"compensate", frame[i].stage, 0, true})
			frame[i].undo()
		}
	}
	return result
}

// NewLawSpecWorkflowRuntime makes a runtime; a nil clock is real time.
func NewLawSpecWorkflowRuntime(clock LawSpecClock, seed uint64) *LawSpecWorkflowRuntime {
	if clock == nil {
		clock = &LawSpecRealClock{time.Now()}
	}
	return &LawSpecWorkflowRuntime{Clock: clock, Random: LawSpecSplitMix64{seed}, State: map[string]any{}, Gates: true}
}

// Context returns a symbols map that runs workflows under this runtime.
func (r *LawSpecWorkflowRuntime) Context(symbols map[string]*LawSpecSymbol) map[string]*LawSpecSymbol {
	if symbols == nil {
		symbols = map[string]*LawSpecSymbol{}
	}
	symbols[lsWorkflowKey] = &lawSpecSymbol{workflow: r}
	return symbols
}

var lsDefaultWorkflowRuntime *LawSpecWorkflowRuntime

// LawSpecUseVirtualClock makes the default runtime virtual, as generated tests do.
func LawSpecUseVirtualClock(seed uint64) {
	lsDefaultWorkflowRuntime = NewLawSpecWorkflowRuntime(&LawSpecVirtualClock{}, seed)
	lsDefaultWorkflowRuntime.Gates = false
}

func lsWorkflowRuntime(symbols map[string]*lawSpecSymbol) *LawSpecWorkflowRuntime {
	if entry, ok := symbols[lsWorkflowKey]; ok && entry.workflow != nil {
		return entry.workflow
	}
	if lsDefaultWorkflowRuntime == nil {
		lsDefaultWorkflowRuntime = NewLawSpecWorkflowRuntime(nil, 0)
	}
	return lsDefaultWorkflowRuntime
}

// lawSpecRetry: Strategy is immediate, fixed, linear, exponential, fibonacci
// or custom; Delay, Step, Factor and Cap (negative for none) are its
// parameters; Decide stops (false) or waits, for custom strategies.
type lawSpecRetry struct {
	Strategy                 string
	Delay, Step, Factor, Cap int64
	Attempts                 int64
	Jitter                   string
	When                     func(LawSpecValue) bool
	Decide                   func(attempt int64, failure LawSpecValue, previous int64) (int64, bool)
}

// lawSpecGate is a stateful policy: Start gives its state, Admit a Step of
// the next state and a Gate (Admit, WaitFor or Reject), and Finish (when
// set) the state after the call. Wait is -2 to fail at once when not
// admitted, -1 to wait without bound, or the most it waits.
type lawSpecGate struct {
	Kind   string
	Start  func(now int64) LawSpecValue
	Admit  func(state LawSpecValue, now int64) LawSpecValue
	Finish func(state LawSpecValue, now int64, succeeded bool) LawSpecValue
	Wait   int64
}

// lawSpecStagePolicy: Key names the stage's state, Cache is how long a
// success is reused (-1 for no cache), and Wraps says failures are
// StageFailures.
type lawSpecStagePolicy struct {
	Stage   string
	Retry   *lawSpecRetry
	Timeout int64
	Key     string
	Gates   []lawSpecGate
	Cache   int64
	Wraps   bool
	// Fail gives the stage's result for a policy failure, of its own type.
	Fail func(kind string) LawSpecValue
	// Compensate undoes the stage's success value when its workflow fails.
	Compensate func(value LawSpecValue)
	Hedge      *lawSpecHedge
}

type lawSpecCacheEntry struct {
	key, value LawSpecValue
	expires    int64
}

const lsStageFailure = "lawspec.resilience::type::StageFailure::"
const lsGate = "lawspec.resilience::type::Gate::"

func lsStageFailureValue(kind string) LawSpecValue {
	return LawSpecValue{"Either", lawSpecData{"Either::Left", []LawSpecValue{
		{"lawspec.resilience::type::StageFailure", lawSpecData{lsStageFailure + kind, nil}}}}}
}

// lsPassGate admits the call, or gives the failure to return instead.
func lsPassGate(runtime *LawSpecWorkflowRuntime, policy lawSpecStagePolicy, gate lawSpecGate) string {
	key := policy.Key + "/" + gate.Kind
	waited := int64(0)
	failure := map[string]string{"breaker": "CircuitOpen", "limit": "RateLimited", "bulkhead": "Saturated"}[gate.Kind]
	for {
		now := runtime.Clock.Now()
		state, ok := runtime.State[key].(LawSpecValue)
		if !ok {
			state = gate.Start(now)
		}
		step := gate.Admit(state, now).Data.(lawSpecData)
		runtime.State[key] = step.fields[0]
		decision := step.fields[1].Data.(lawSpecData)
		if decision.tag == lsGate+"Admit" {
			return ""
		}
		if decision.tag == lsGate+"Reject" || gate.Wait == -2 {
			return failure
		}
		delay := decision.fields[0].Data.(*big.Int).Int64()
		if gate.Wait >= 0 && waited+delay > gate.Wait {
			return failure
		}
		runtime.Trace = append(runtime.Trace, LawSpecTraceEvent{"wait", policy.Stage, delay, true})
		runtime.Clock.Sleep(delay)
		waited += delay
	}
}

func lsFinishGate(runtime *LawSpecWorkflowRuntime, policy lawSpecStagePolicy, gate lawSpecGate, succeeded bool) {
	if gate.Finish != nil {
		key := policy.Key + "/" + gate.Kind
		runtime.State[key] = gate.Finish(runtime.State[key].(LawSpecValue), runtime.Clock.Now(), succeeded)
	}
}

func lsFibonacci(n int64) int64 {
	a, b := int64(1), int64(1)
	for i := int64(1); i < n; i++ {
		a, b = b, a+b
	}
	return a
}

// lsRetryDelay is the delay before attempt (2 or more), before jitter.
func lsRetryDelay(retry *lawSpecRetry, attempt int64) int64 {
	n := attempt - 1
	switch retry.Strategy {
	case "immediate":
		return 0
	case "fixed":
		return retry.Delay
	case "linear":
		return retry.Delay + retry.Step*(n-1)
	case "exponential":
		delay := retry.Delay
		for i := int64(1); i < n; i++ {
			delay *= retry.Factor
			if retry.Cap >= 0 && delay >= retry.Cap {
				return retry.Cap
			}
		}
		if retry.Cap >= 0 && delay > retry.Cap {
			return retry.Cap
		}
		return delay
	case "fibonacci":
		return retry.Delay * lsFibonacci(n)
	}
	panic("unknown retry strategy: " + retry.Strategy)
}

// lsJittered: full is [0, delay]; equal is delay/2 + [0, delay/2];
// decorrelated is [base, previous * 3], capped at delay.
func lsJittered(jitter string, delay, previous, base int64, random *LawSpecSplitMix64) int64 {
	switch jitter {
	case "full":
		return int64(random.Below(uint64(delay + 1)))
	case "equal":
		half := delay / 2
		return half + int64(random.Below(uint64(delay-half+1)))
	case "decorrelated":
		high := previous * 3
		if high < base {
			high = base
		}
		value := base + int64(random.Below(uint64(high-base+1)))
		if value > delay {
			return delay
		}
		return value
	}
	return delay
}

// lsRunStage runs a stage's attempts under its policy; a Left is a failure.
// key is the stage's input, for the cache.
func lsRunStage(symbols map[string]*lawSpecSymbol, policy lawSpecStagePolicy, attempt func() LawSpecValue, key LawSpecValue) LawSpecValue {
	runtime := lsWorkflowRuntime(symbols)
	if policy.Key == "" {
		policy.Key = policy.Stage
	}
	gates := policy.Gates
	if !runtime.Gates {
		gates = nil
	}
	cacheKey := policy.Key + "/cache"
	// A cache of no time (or none, -1) caches nothing.
	caching := policy.Cache > 0 && runtime.Gates
	if caching {
		now := runtime.Clock.Now()
		entries, _ := runtime.State[cacheKey].([]lawSpecCacheEntry)
		for _, entry := range entries {
			if now < entry.expires && lsCompareValues(entry.key, key) == 0 {
				runtime.Trace = append(runtime.Trace, LawSpecTraceEvent{"cached", policy.Stage, 0, true})
				return entry.value
			}
		}
	}
	for i, gate := range gates {
		if failure := lsPassGate(runtime, policy, gate); failure != "" {
			for _, passed := range gates[:i] {
				lsFinishGate(runtime, policy, passed, false)
			}
			if policy.Fail != nil {
				return policy.Fail(failure)
			}
			return lsStageFailureValue(failure)
		}
	}
	result := lsAttempts(runtime, policy, attempt)
	data, isData := result.Data.(lawSpecData)
	succeeded := !(isData && data.tag == "Either::Left")
	for _, gate := range gates {
		lsFinishGate(runtime, policy, gate, succeeded)
	}
	if succeeded && policy.Compensate != nil && len(runtime.frames) > 0 {
		value := data.fields[0]
		last := len(runtime.frames) - 1
		runtime.frames[last] = append(runtime.frames[last], lawSpecUndo{policy.Stage, func() { policy.Compensate(value) }})
	}
	if caching && succeeded {
		entries, _ := runtime.State[cacheKey].([]lawSpecCacheEntry)
		kept := []lawSpecCacheEntry{}
		for _, entry := range entries {
			if lsCompareValues(entry.key, key) != 0 {
				kept = append(kept, entry)
			}
		}
		runtime.State[cacheKey] = append(kept, lawSpecCacheEntry{key, result, runtime.Clock.Now() + policy.Cache})
	}
	return result
}

func lsAttempts(runtime *LawSpecWorkflowRuntime, policy lawSpecStagePolicy, attempt func() LawSpecValue) LawSpecValue {
	retry := policy.Retry
	number, previous := int64(1), int64(0)
	for {
		runtime.Trace = append(runtime.Trace, LawSpecTraceEvent{"start", policy.Stage, number, false})
		result := lsScoped(runtime, policy, attempt)
		data, isData := result.Data.(lawSpecData)
		failed := isData && data.tag == "Either::Left"
		runtime.Trace = append(runtime.Trace, LawSpecTraceEvent{"finish", policy.Stage, number, !failed})
		if !failed || retry == nil {
			return result
		}
		if retry.Attempts > 0 && number >= retry.Attempts {
			return result
		}
		failure := data.fields[0]
		if policy.Wraps {
			// Only the step's own failures and timeouts are retried.
			wrapped := failure.Data.(lawSpecData)
			if wrapped.tag == lsStageFailure+"StepFailed" {
				failure = wrapped.fields[0]
			} else if wrapped.tag != lsStageFailure+"TimedOut" {
				return result
			}
		}
		if retry.When != nil && !retry.When(failure) {
			return result
		}
		number++
		var delay int64
		if retry.Strategy == "custom" {
			wait, ok := retry.Decide(number, failure, previous)
			if !ok {
				return result
			}
			delay = wait
		} else {
			base := int64(0)
			if retry.Strategy != "immediate" {
				base = lsRetryDelay(retry, 2)
			}
			delay = lsJittered(retry.Jitter, lsRetryDelay(retry, number), previous, base, &runtime.Random)
		}
		runtime.Trace = append(runtime.Trace, LawSpecTraceEvent{"sleep", policy.Stage, delay, true})
		runtime.Clock.Sleep(delay)
		previous = delay
	}
}

func lsInteger64(n int64) LawSpecValue { return LawSpecValue{"Integer", big.NewInt(n)} }

// lsDuration is a logical Duration of whole microseconds.
func lsDuration(micros int64) LawSpecValue {
	return LawSpecValue{"lawspec.time::type::Duration", lawSpecData{"lawspec.time::type::Duration::Duration", []LawSpecValue{lsInteger64(micros)}}}
}

// lsRetryDecision reads a RetryDecision: RetryAfter's delay, or false to stop.
func lsRetryDecision(decision LawSpecValue) (int64, bool) {
	data := decision.Data.(lawSpecData)
	if data.tag != "lawspec.time::type::RetryDecision::RetryAfter" {
		return 0, false
	}
	delay := data.fields[0].Data.(lawSpecData).fields[0].Data.(*big.Int)
	return delay.Int64(), true
}

// Portable generation for stateful models. A type descriptor is an
// s-expression: (int T lo hi) with _ for no bound, (bool), (text), (unit),
// (list D), (maybe D), (either L R), (data NAME (ctor TAG D...) ...) and
// (ref NAME) for a data type declared in the model's table. Every target
// generates, shrinks and renders the same values for the same seed. Values
// are logical: a data type's value has its NAME as Type.

// lawSpecQuoted is a string atom of a descriptor; a bare atom is a string.
type lawSpecQuoted string

// lsReadDescriptor parses s-expressions: lists ([]any), integers (*big.Int),
// strings, symbols and _ (nil).
func lsReadDescriptor(source string) []any {
	text := []rune(source)
	position := 0
	space := func(c rune) bool { return c == ' ' || c == '\t' || c == '\r' || c == '\n' }
	skip := func() {
		for position < len(text) && space(text[position]) {
			position++
		}
	}
	var item func() any
	item = func() any {
		skip()
		c := text[position]
		if c == '(' {
			position++
			items := []any{}
			skip()
			for text[position] != ')' {
				items = append(items, item())
				skip()
			}
			position++
			return items
		}
		if c == '"' {
			position++
			out := []rune{}
			for text[position] != '"' {
				if text[position] == '\\' {
					position++
				}
				out = append(out, text[position])
				position++
			}
			position++
			return lawSpecQuoted(string(out))
		}
		start := position
		for position < len(text) && !space(text[position]) && text[position] != '(' && text[position] != ')' {
			position++
		}
		atom := string(text[start:position])
		if atom == "_" {
			return nil
		}
		if digits := strings.TrimLeft(atom, "-"); digits != "" && strings.Trim(digits, "0123456789") == "" {
			return lsInt(atom)
		}
		return atom
	}
	items := []any{}
	skip()
	for position < len(text) {
		items = append(items, item())
		skip()
	}
	return items
}

// lsAtom is an atom's text, quoted or not.
func lsAtom(x any) string {
	switch x := x.(type) {
	case string:
		return x
	case lawSpecQuoted:
		return string(x)
	}
	return fmt.Sprint(x)
}

// lsBelowBig is SplitMix64's Below for any bound, 2^64 (the full UInt64
// range) included: the raw draw modulo the bound.
func lsBelowBig(random *LawSpecSplitMix64, bound *big.Int) *big.Int {
	if bound.Sign() <= 0 {
		return new(big.Int)
	}
	draw := new(big.Int).SetUint64(random.Next())
	return draw.Mod(draw, bound)
}

// lsBelowCount is Below for a signed count; nothing is drawn below 1.
func lsBelowCount(random *LawSpecSplitMix64, bound int64) int64 {
	if bound <= 0 {
		return 0
	}
	return int64(random.Below(uint64(bound)))
}

const lsUnbounded = 1_000_000

// lawSpecValues generates, shrinks and renders over a table of data types.
type lawSpecValues struct{ table map[string][]any }

func (s lawSpecValues) resolve(d any) []any {
	form := d.([]any)
	if lsAtom(form[0]) == "ref" {
		return s.table[lsAtom(form[1])]
	}
	return form
}

// typeOf is the logical type name the runtime's codecs give such a value.
func (s lawSpecValues) typeOf(d any) string {
	form := s.resolve(d)
	switch lsAtom(form[0]) {
	case "int":
		return lsAtom(form[1])
	case "bool":
		return "Bool"
	case "text":
		return "Text"
	case "unit":
		return "Unit"
	case "list":
		return "List " + s.typeOf(form[1])
	case "maybe":
		return "Maybe " + s.typeOf(form[1])
	case "either":
		return "Either (" + s.typeOf(form[1]) + ") (" + s.typeOf(form[2]) + ")"
	}
	return lsAtom(form[1])
}

// bounds is an integer's range: a missing bound is 1,000,000 from zero, or
// 2,000,000 from the other bound when that is beyond it.
func (s lawSpecValues) bounds(d []any) (*big.Int, *big.Int) {
	unbounded, twice := big.NewInt(lsUnbounded), big.NewInt(2*lsUnbounded)
	lo, _ := d[2].(*big.Int)
	hi, _ := d[3].(*big.Int)
	switch {
	case lo == nil && hi == nil:
		return new(big.Int).Neg(unbounded), unbounded
	case lo == nil:
		low := new(big.Int).Sub(hi, twice)
		if minus := new(big.Int).Neg(unbounded); minus.Cmp(low) < 0 {
			low = minus
		}
		return low, hi
	case hi == nil:
		high := new(big.Int).Add(lo, twice)
		if unbounded.Cmp(high) > 0 {
			high = unbounded
		}
		return lo, high
	}
	return lo, hi
}

// lsClamp is min(max(n, lo), hi).
func lsClamp(n int64, lo, hi *big.Int) *big.Int {
	x := big.NewInt(n)
	if x.Cmp(lo) < 0 {
		x = lo
	}
	if x.Cmp(hi) > 0 {
		x = hi
	}
	return new(big.Int).Set(x)
}

func lsMentionsData(d any) bool {
	form, ok := d.([]any)
	if !ok {
		return false
	}
	if kind := lsAtom(form[0]); kind == "ref" || kind == "data" {
		return true
	}
	for _, x := range form[1:] {
		if lsMentionsData(x) {
			return true
		}
	}
	return false
}

// base is the constructors whose fields mention no data type.
func (s lawSpecValues) base(d []any) []any {
	found := []any{}
	for _, c := range d[2:] {
		mentions := false
		for _, f := range c.([]any)[2:] {
			mentions = mentions || lsMentionsData(f)
		}
		if !mentions {
			found = append(found, c)
		}
	}
	if len(found) == 0 {
		return d[2:]
	}
	return found
}

func lsSum(t, tag string, fields ...LawSpecValue) LawSpecValue {
	if len(fields) == 0 {
		fields = nil
	}
	return LawSpecValue{t, lawSpecData{tag, fields}}
}

func (s lawSpecValues) generate(d any, random *LawSpecSplitMix64, size int64) LawSpecValue {
	form := s.resolve(d)
	t := s.typeOf(form)
	switch lsAtom(form[0]) {
	case "int":
		lo, hi := s.bounds(form)
		if random.Below(10) < 2 {
			specials := []*big.Int{lo, hi, lsClamp(0, lo, hi), lsClamp(1, lo, hi)}
			return LawSpecValue{t, new(big.Int).Set(specials[random.Below(4)])}
		}
		span := new(big.Int).Sub(hi, lo)
		offset := lsBelowBig(random, span.Add(span, big.NewInt(1)))
		return LawSpecValue{t, offset.Add(offset, lo)}
	case "bool":
		return lsBool(random.Below(2) == 1)
	case "text":
		units := []int{}
		for n := lsBelowCount(random, size+1); n > 0; n-- {
			units = append(units, 32+int(random.Below(95)))
		}
		return LawSpecValue{t, units}
	case "unit":
		return LawSpecValue{t, nil}
	case "list":
		items := []LawSpecValue{}
		for n := lsBelowCount(random, size+1); n > 0; n-- {
			items = append(items, s.generate(form[1], random, size))
		}
		return LawSpecValue{t, items}
	case "maybe":
		if random.Below(4) == 0 {
			return lsSum(t, "Maybe::Nothing")
		}
		return lsSum(t, "Maybe::Just", s.generate(form[1], random, size))
	case "either":
		if random.Below(2) == 0 {
			return lsSum(t, "Either::Left", s.generate(form[1], random, size))
		}
		return lsSum(t, "Either::Right", s.generate(form[2], random, size))
	case "data":
		choices := form[2:]
		if size <= 0 {
			choices = s.base(form)
		}
		ctor := choices[random.Below(uint64(len(choices)))].([]any)
		fields := []LawSpecValue{}
		for _, f := range ctor[2:] {
			fields = append(fields, s.generate(f, random, max(size-1, 0)))
		}
		return lsSum(t, lsAtom(ctor[1]), fields...)
	}
	panic("unknown descriptor " + fmt.Sprint(form))
}

func (s lawSpecValues) minimal(d any) LawSpecValue {
	form := s.resolve(d)
	t := s.typeOf(form)
	switch lsAtom(form[0]) {
	case "int":
		lo, hi := s.bounds(form)
		return LawSpecValue{t, lsClamp(0, lo, hi)}
	case "bool":
		return lsBool(false)
	case "text":
		return LawSpecValue{t, []int{}}
	case "unit":
		return LawSpecValue{t, nil}
	case "list":
		return LawSpecValue{t, []LawSpecValue{}}
	case "maybe":
		return lsSum(t, "Maybe::Nothing")
	case "either":
		return lsSum(t, "Either::Left", s.minimal(form[1]))
	}
	ctor := s.base(form)[0].([]any)
	fields := []LawSpecValue{}
	for _, f := range ctor[2:] {
		fields = append(fields, s.minimal(f))
	}
	return lsSum(t, lsAtom(ctor[1]), fields...)
}

// lsSplice is items with index i replaced by the given values (or removed).
func lsSplice[T any](items []T, i int, with ...T) []T {
	out := append([]T{}, items[:i]...)
	out = append(out, with...)
	return append(out, items[i+1:]...)
}

// shrink is smaller candidates for v, most aggressive first.
func (s lawSpecValues) shrink(d any, v LawSpecValue) []LawSpecValue {
	form := s.resolve(d)
	t := s.typeOf(form)
	out := []LawSpecValue{}
	switch lsAtom(form[0]) {
	case "int":
		target := s.minimal(form)
		x, goal := v.Data.(*big.Int), target.Data.(*big.Int)
		if x.Cmp(goal) != 0 {
			// big.Int's Quo truncates toward zero.
			half := new(big.Int).Quo(new(big.Int).Sub(x, goal), big.NewInt(2))
			step := big.NewInt(-1)
			if x.Cmp(goal) > 0 {
				step = big.NewInt(1)
			}
			out = []LawSpecValue{target, {t, half.Sub(x, half)}, {t, step.Sub(x, step)}}
		}
	case "bool":
		if v.Data.(bool) {
			out = []LawSpecValue{lsBool(false)}
		}
	case "text":
		units := v.Data.([]int)
		if len(units) > 0 {
			out = []LawSpecValue{{t, []int{}}, {t, append([]int{}, units[:len(units)/2]...)}}
			for i := range units {
				out = append(out, LawSpecValue{t, lsSplice(units, i)})
			}
		}
	case "list":
		items := v.Data.([]LawSpecValue)
		if len(items) > 0 {
			out = []LawSpecValue{{t, []LawSpecValue{}}, {t, append([]LawSpecValue{}, items[:len(items)/2]...)}}
			for i := range items {
				out = append(out, LawSpecValue{t, lsSplice(items, i)})
			}
			for i, item := range items {
				for _, c := range s.shrink(form[1], item) {
					out = append(out, LawSpecValue{t, lsSplice(items, i, c)})
				}
			}
		}
	case "maybe":
		data := v.Data.(lawSpecData)
		if data.tag == "Maybe::Just" {
			out = []LawSpecValue{lsSum(t, "Maybe::Nothing")}
			for _, c := range s.shrink(form[1], data.fields[0]) {
				out = append(out, lsSum(t, "Maybe::Just", c))
			}
		}
	case "either":
		data := v.Data.(lawSpecData)
		inner := form[2]
		if data.tag == "Either::Left" {
			inner = form[1]
		}
		for _, c := range s.shrink(inner, data.fields[0]) {
			out = append(out, lsSum(t, data.tag, c))
		}
	case "data":
		data := v.Data.(lawSpecData)
		var ctor []any
		for _, c := range form[2:] {
			if lsAtom(c.([]any)[1]) == data.tag {
				ctor = c.([]any)
				break
			}
		}
		out = []LawSpecValue{s.minimal(form)}
		// A field of the same type is a smaller value of it.
		for i, fd := range ctor[2:] {
			if ref, ok := fd.([]any); ok && len(ref) == 2 && lsAtom(ref[0]) == "ref" && lsAtom(ref[1]) == lsAtom(form[1]) {
				out = append(out, data.fields[i])
			}
		}
		for i, fd := range ctor[2:] {
			for _, c := range s.shrink(fd, data.fields[i]) {
				out = append(out, lsSum(t, data.tag, lsSplice(data.fields, i, c)...))
			}
		}
	}
	// Candidates are distinct by rendered text, and none is v itself.
	seen := map[string]bool{lsRender(v): true}
	unique := []LawSpecValue{}
	for _, c := range out {
		if text := lsRender(c); !seen[text] {
			seen[text] = true
			unique = append(unique, c)
		}
	}
	return unique
}

// lsRender is a value's canonical text, the same on every target.
func lsRender(v LawSpecValue) string {
	switch x := v.Data.(type) {
	case bool:
		return strconv.FormatBool(x)
	case *big.Int:
		return x.String()
	case []int:
		var b strings.Builder
		b.WriteByte('"')
		for _, c := range x {
			if c == '\\' || c == '"' {
				b.WriteByte('\\')
			}
			b.WriteRune(rune(c))
		}
		b.WriteByte('"')
		return b.String()
	case nil:
		return "()"
	case []LawSpecValue:
		parts := make([]string, len(x))
		for i, item := range x {
			parts[i] = lsRender(item)
		}
		return "[" + strings.Join(parts, ", ") + "]"
	case lawSpecData:
		segments := strings.Split(x.tag, "::")
		name := segments[len(segments)-1]
		if len(x.fields) == 0 {
			return name
		}
		parts := make([]string, len(x.fields))
		for i, field := range x.fields {
			parts[i] = lsRender(field)
		}
		return name + "(" + strings.Join(parts, ", ") + ")"
	case lawSpecHandle:
		return lsHandleLabel(v.Type, x.native)
	}
	return fmt.Sprint(v.Data)
}

// lsValuesFrom is a descriptor text's data types and its last form, the one
// generated.
func lsValuesFrom(text string) (lawSpecValues, any) {
	forms := lsReadDescriptor(text)
	table := map[string][]any{}
	for _, f := range forms {
		if form, ok := f.([]any); ok && lsAtom(form[0]) == "data" {
			table[lsAtom(form[1])] = form
		}
	}
	return lawSpecValues{table}, forms[len(forms)-1]
}

// LawSpecGenerated is count values generated from one SplitMix64 seed, rendered.
func LawSpecGenerated(text string, seed uint64, size int64, count int64) []string {
	values, d := lsValuesFrom(text)
	random := LawSpecSplitMix64{seed}
	result := []string{}
	for ; count > 0; count-- {
		result = append(result, lsRender(values.generate(d, &random, size)))
	}
	return result
}

// LawSpecShrunk is the shrink candidates of the first value generated, rendered.
func LawSpecShrunk(text string, seed uint64, size int64) []string {
	values, d := lsValuesFrom(text)
	random := LawSpecSplitMix64{seed}
	result := []string{}
	for _, c := range values.shrink(d, values.generate(d, &random, size)) {
		result = append(result, lsRender(c))
	}
	return result
}

// Stateful models. A model's spec (see LawSpec.MachineSpec) lists its data
// types, start and commands; the callbacks beside it are the generated
// definitions that call the adapters, the references over the model state,
// preconditions, the abstraction and invariants, each taking symbols first.
// A run is generated by simulating the pure model, so every command in it is
// allowed by typestate, its precondition and its reference; it is then
// executed against the adapters and every result, abstracted state and
// invariant is checked. A failing run is shrunk by dropping commands and
// shrinking arguments, replaying the model to keep each candidate valid.
// Errors from generated definitions are panics, recovered here.

// LawSpecModelCallback is a generated definition: symbols, then arguments.
type LawSpecModelCallback func(symbols map[string]*LawSpecSymbol, args []LawSpecValue) LawSpecValue

// LawSpecModel is a model's spec and its callbacks. Start is the system's
// start and the model's; each command is its run, reference and
// precondition (nil when absent); Abstract may be nil.
type LawSpecModel struct {
	Spec       string
	Start      [2]LawSpecModelCallback
	Commands   [][3]LawSpecModelCallback
	Abstract   LawSpecModelCallback
	Invariants []LawSpecModelCallback
}

type lawSpecModelCommand struct {
	name                 string
	arguments            []any
	state                int
	unit                 bool
	needs, shifts        [][2]any
	key                  int // the argument naming the key it touches, for per-key checks; -1 when none
	run, reference, when LawSpecModelCallback
}

type lawSpecMachine struct {
	name           string
	shared         bool
	values         lawSpecValues
	startIndices   []int64
	startArguments []any
	startRun       LawSpecModelCallback
	startModel     LawSpecModelCallback
	commands       []lawSpecModelCommand
	abstract       LawSpecModelCallback
	invariantKinds []string
	invariants     []LawSpecModelCallback
	perKey         bool
}

type lawSpecModelStep struct {
	index int
	args  []LawSpecValue
}

type lawSpecModelRun struct {
	start []LawSpecValue
	steps []lawSpecModelStep
}

// lawSpecInvalid is panicked for a command the model does not allow here.
type lawSpecInvalid struct{}

func lsFormFields(forms []any) map[string][]any {
	fields := map[string][]any{}
	for _, f := range forms {
		form := f.([]any)
		fields[lsAtom(form[0])] = form[1:]
	}
	return fields
}

func lsPairs(forms []any) [][2]any {
	pairs := [][2]any{}
	for _, f := range forms {
		form := f.([]any)
		pairs = append(pairs, [2]any{lsAtom(form[0]), form[1].(*big.Int).Int64()})
	}
	return pairs
}

func (c *lawSpecModelCommand) admits(indices []int64) bool {
	for k := 0; k < len(c.needs) && k < len(indices); k++ {
		n := c.needs[k][1].(int64)
		if c.needs[k][0] == "atleast" {
			if indices[k] < n {
				return false
			}
		} else if indices[k] != n {
			return false
		}
	}
	return true
}

func (c *lawSpecModelCommand) shifted(indices []int64) []int64 {
	out := []int64{}
	for k := 0; k < len(c.shifts) && k < len(indices); k++ {
		s := c.shifts[k][1].(int64)
		if c.shifts[k][0] == "by" {
			out = append(out, indices[k]+s)
		} else {
			out = append(out, s)
		}
	}
	return out
}

func lsNewMachine(model LawSpecModel) *lawSpecMachine {
	forms := lsReadDescriptor(model.Spec)
	head := forms[0].([]any)
	m := &lawSpecMachine{name: lsAtom(head[1]), shared: lsAtom(head[2]) == "shared"}
	table := map[string][]any{}
	commandIndex := 0
	for _, f := range forms {
		form := f.([]any)
		switch lsAtom(form[0]) {
		case "data":
			table[lsAtom(form[1])] = form
		case "start":
			fields := lsFormFields(form[1:])
			for _, i := range fields["indices"] {
				m.startIndices = append(m.startIndices, i.(*big.Int).Int64())
			}
			m.startArguments = fields["arguments"]
		case "command":
			fields := lsFormFields(form[2:])
			callbacks := model.Commands[commandIndex]
			commandIndex++
			key := -1
			if k, ok := fields["key"]; ok && len(k) > 0 {
				if n, isNumber := k[0].(*big.Int); isNumber {
					key = int(n.Int64())
				}
			}
			m.commands = append(m.commands, lawSpecModelCommand{
				name:      lsAtom(form[1]),
				arguments: fields["arguments"],
				state:     int(fields["state"][0].(*big.Int).Int64()),
				unit:      lsAtom(fields["unit"][0]) == "true",
				needs:     lsPairs(fields["needs"]),
				shifts:    lsPairs(fields["shifts"]),
				key:       key,
				run:       callbacks[0], reference: callbacks[1], when: callbacks[2],
			})
		case "invariants":
			for _, k := range form[1:] {
				m.invariantKinds = append(m.invariantKinds, lsAtom(k))
			}
		case "perkey":
			m.perKey = len(form) > 1 && lsAtom(form[1]) == "true"
		}
	}
	m.values = lawSpecValues{table}
	m.startRun, m.startModel = model.Start[0], model.Start[1]
	m.abstract = model.Abstract
	m.invariants = model.Invariants
	return m
}

func lsFields(v LawSpecValue) []LawSpecValue { return v.Data.(lawSpecData).fields }

// lsStepModel is the model's next state and result, panicking lawSpecInvalid
// when the command is not allowed (its precondition or reference fails).
func lsStepModel(c *lawSpecModelCommand, symbols map[string]*LawSpecSymbol, args []LawSpecValue, state LawSpecValue) (next, result LawSpecValue) {
	out := func() (out LawSpecValue) {
		defer func() {
			if recover() != nil {
				panic(lawSpecInvalid{})
			}
		}()
		if c.when != nil && !lsTruth(c.when(symbols, []LawSpecValue{state})) {
			panic(lawSpecInvalid{})
		}
		full := append(append([]LawSpecValue{}, args...), state)
		return c.reference(symbols, full)
	}()
	if c.unit {
		return out, lsAbsent("Unit")
	}
	fields := lsFields(out)
	return fields[1], fields[0]
}

// lsAllowed is whether f runs without panicking lawSpecInvalid; other
// panics propagate.
func lsAllowed(f func()) (allowed bool) {
	defer func() {
		if r := recover(); r != nil {
			if _, ok := r.(lawSpecInvalid); !ok {
				panic(r)
			}
			allowed = false
		}
	}()
	f()
	return true
}

// startState is the model's start state, panicking lawSpecInvalid on failure.
func (m *lawSpecMachine) startState(symbols map[string]*LawSpecSymbol, args []LawSpecValue) (state LawSpecValue) {
	defer func() {
		if recover() != nil {
			panic(lawSpecInvalid{})
		}
	}()
	return m.startModel(symbols, args)
}

// simulate is whether the model allows the run.
func (m *lawSpecMachine) simulate(run lawSpecModelRun) bool {
	symbols := map[string]*LawSpecSymbol{}
	return lsAllowed(func() {
		state := m.startState(symbols, run.start)
		indices := append([]int64{}, m.startIndices...)
		for _, step := range run.steps {
			c := &m.commands[step.index]
			if !c.admits(indices) {
				panic(lawSpecInvalid{})
			}
			state, _ = lsStepModel(c, symbols, step.args, state)
			indices = c.shifted(indices)
		}
	})
}

func (m *lawSpecMachine) generateRun(random *LawSpecSplitMix64, length, size int64) lawSpecModelRun {
	symbols := map[string]*LawSpecSymbol{}
	start := []LawSpecValue{}
	for _, d := range m.startArguments {
		start = append(start, m.values.generate(d, random, size))
	}
	run := lawSpecModelRun{start: start}
	var state LawSpecValue
	if !lsAllowed(func() { state = m.startState(symbols, start) }) {
		return run
	}
	indices := append([]int64{}, m.startIndices...)
	for ; length > 0; length-- {
		allowed := []int{}
		for i := range m.commands {
			if m.commands[i].admits(indices) {
				allowed = append(allowed, i)
			}
		}
		if len(allowed) == 0 {
			break
		}
		index := allowed[random.Below(uint64(len(allowed)))]
		c := &m.commands[index]
		args := []LawSpecValue{}
		for _, d := range c.arguments {
			args = append(args, m.values.generate(d, random, size))
		}
		if !lsAllowed(func() { state, _ = lsStepModel(c, symbols, args, state) }) {
			continue
		}
		run.steps = append(run.steps, lawSpecModelStep{index, args})
		indices = c.shifted(indices)
	}
	return run
}

// execute is the failing step's number and what went wrong, or failed false
// when the system agrees with the model along the run.
func (m *lawSpecMachine) execute(run lawSpecModelRun) (step int, message string, failed bool) {
	symbols := map[string]*LawSpecSymbol{}
	defer func() {
		if r := recover(); r != nil {
			failed = true
			if _, ok := r.(lawSpecInvalid); ok {
				message = "the model does not allow this step"
			} else {
				message = fmt.Sprintf("raised panic: %v", r)
			}
		}
	}()
	state := m.startRun(symbols, run.start)
	expected := m.startModel(symbols, run.start)
	if message, failed = m.checkState(symbols, state, expected); failed {
		return
	}
	for _, s := range run.steps {
		step++
		c := &m.commands[s.index]
		full := append(append([]LawSpecValue{}, s.args[:c.state]...), state)
		full = append(full, s.args[c.state:]...)
		out := c.run(symbols, full)
		var result LawSpecValue
		if m.shared {
			result = out
		} else {
			fields := lsFields(out)
			if c.unit {
				result = lsAbsent("Unit")
			} else {
				result = fields[0]
			}
			state = fields[len(fields)-1]
		}
		var wanted LawSpecValue
		expected, wanted = lsStepModel(c, symbols, s.args, expected)
		if !c.unit && lsCompareValues(result, wanted) != 0 {
			return step, fmt.Sprintf("returned %s; the model returns %s", lsRender(result), lsRender(wanted)), true
		}
		if message, failed = m.checkState(symbols, state, expected); failed {
			return
		}
	}
	return 0, "", false
}

func (m *lawSpecMachine) checkState(symbols map[string]*LawSpecSymbol, state, expected LawSpecValue) (string, bool) {
	if m.abstract != nil {
		actual := m.abstract(symbols, []LawSpecValue{state})
		if lsCompareValues(actual, expected) != 0 {
			return fmt.Sprintf("the state is %s; the model is %s", lsRender(actual), lsRender(expected)), true
		}
	}
	for i, kind := range m.invariantKinds {
		if i >= len(m.invariants) {
			break
		}
		subject := state
		if kind == "model" {
			subject = expected
		}
		if !lsTruth(m.invariants[i](symbols, []LawSpecValue{subject})) {
			return "an invariant on the " + kind + " fails", true
		}
	}
	return "", false
}

// shrinkCandidates calls yield on each candidate in order until it returns false.
func (m *lawSpecMachine) shrinkCandidates(run lawSpecModelRun, yield func(lawSpecModelRun) bool) {
	steps := run.steps
	n := len(steps)
	for size := n / 2; size >= 1; size /= 2 {
		for begin := 0; begin < n; begin += size {
			kept := append([]lawSpecModelStep{}, steps[:begin]...)
			kept = append(kept, steps[min(begin+size, n):]...)
			if !yield(lawSpecModelRun{run.start, kept}) {
				return
			}
		}
	}
	for k, s := range steps {
		c := &m.commands[s.index]
		for j := 0; j < len(c.arguments) && j < len(s.args); j++ {
			for _, candidate := range m.values.shrink(c.arguments[j], s.args[j]) {
				args := append([]LawSpecValue{}, s.args...)
				args[j] = candidate
				changed := append([]lawSpecModelStep{}, steps...)
				changed[k] = lawSpecModelStep{s.index, args}
				if !yield(lawSpecModelRun{run.start, changed}) {
					return
				}
			}
		}
	}
	for j := 0; j < len(m.startArguments) && j < len(run.start); j++ {
		for _, candidate := range m.values.shrink(m.startArguments[j], run.start[j]) {
			start := append([]LawSpecValue{}, run.start...)
			start[j] = candidate
			if !yield(lawSpecModelRun{start, steps}) {
				return
			}
		}
	}
}

func (m *lawSpecMachine) shrinkRun(run lawSpecModelRun, step int, message string, budget int) (lawSpecModelRun, int, string) {
	for budget > 0 {
		found := false
		m.shrinkCandidates(run, func(candidate lawSpecModelRun) bool {
			budget--
			if budget <= 0 {
				return false
			}
			if !m.simulate(candidate) {
				return true
			}
			if k, text, failed := m.execute(candidate); failed {
				run, step, message, found = candidate, k, text, true
				return false
			}
			return true
		})
		if !found {
			break
		}
	}
	return run, step, message
}

func (m *lawSpecMachine) describeRun(run lawSpecModelRun) string {
	render := func(values []LawSpecValue) string {
		parts := make([]string, len(values))
		for i, v := range values {
			parts[i] = lsRender(v)
		}
		return strings.Join(parts, ", ")
	}
	parts := []string{"start(" + render(run.start) + ")"}
	for _, s := range run.steps {
		parts = append(parts, m.commands[s.index].name+"("+render(s.args)+")")
	}
	return strings.Join(parts, "; ")
}

// LawSpecCheckModel checks the system against its model on generated runs
// (100 cases of at most 20 commands, seeded from LAWSPEC_SEED); a failure is
// an error naming the shortest failing run found.
func LawSpecCheckModel(model LawSpecModel) error {
	var seed uint64
	if text := os.Getenv("LAWSPEC_SEED"); text != "" {
		parsed, err := strconv.ParseUint(text, 10, 64)
		if err != nil {
			return fmt.Errorf("invalid LAWSPEC_SEED %q", text)
		}
		seed = parsed
	}
	return lsCheckModel(model, 100, 20, 2000, seed)
}

func lsCheckModel(model LawSpecModel, cases, maxLength, maxShrinks int, seed uint64) error {
	m := lsNewMachine(model)
	random := &LawSpecSplitMix64{seed}
	for c := 0; c < cases; c++ {
		length := int64(random.Below(uint64(maxLength + 1)))
		run := m.generateRun(random, length, int64(1+c%8))
		if step, message, failed := m.execute(run); failed {
			run, step, message = m.shrinkRun(run, step, message, maxShrinks)
			return fmt.Errorf("model %s fails at step %d of %s: %s", m.name, step, m.describeRun(run), message)
		}
	}
	return nil
}

// Parallel runs of a shared model. A case is a sequential prefix and one
// branch per thread, generated so that the model allows every interleaving
// of the branches (a search over each thread's position and the model state,
// memoized). The system runs the branches at the same time, each call's start
// and return recorded on one counter, with random yields and short sleeps
// around calls to shake out rare schedules. The history must be
// linearizable: some interleaving that keeps every call after those that
// returned before it started must give every result the model gives and
// leave the state it leaves (a Wing-Gong search, memoized on the same
// positions and model state). Each case runs several times.

const (
	lawSpecParallelThreads = 3
	lawSpecParallelBranch  = 5
)

type lawSpecParallelCase struct {
	prefix   lawSpecModelRun
	branches [][]lawSpecModelStep
}

// lawSpecCall is a branch call's history: when it started and returned on
// a shared counter, and its result.
type lawSpecCall struct {
	called, returned int64
	result           LawSpecValue
}

// simulateState is the model's state after the run, panicking lawSpecInvalid
// when the model does not allow it.
func (m *lawSpecMachine) simulateState(symbols map[string]*LawSpecSymbol, run lawSpecModelRun) LawSpecValue {
	state := m.startState(symbols, run.start)
	indices := append([]int64{}, m.startIndices...)
	for _, step := range run.steps {
		c := &m.commands[step.index]
		if !c.admits(indices) {
			panic(lawSpecInvalid{})
		}
		state, _ = lsStepModel(c, symbols, step.args, state)
		indices = c.shifted(indices)
	}
	return state
}

// lsAdvanced is the positions with thread i one step further.
func lsAdvanced(positions []int, i int) []int {
	next := append([]int{}, positions...)
	next[i]++
	return next
}

// lsPositionsKey is the memo key of the threads' positions and a model state.
func lsPositionsKey(positions []int, state LawSpecValue) string {
	return fmt.Sprint(positions) + "|" + lsRender(state)
}

// parallelAllowed is whether the model allows the prefix then every
// interleaving of the branches.
func (m *lawSpecMachine) parallelAllowed(c lawSpecParallelCase) bool {
	symbols := map[string]*LawSpecSymbol{}
	var start LawSpecValue
	if !lsAllowed(func() { start = m.simulateState(symbols, c.prefix) }) {
		return false
	}
	seen := map[string]bool{}
	var visit func(positions []int, state LawSpecValue) bool
	visit = func(positions []int, state LawSpecValue) bool {
		key := lsPositionsKey(positions, state)
		if seen[key] {
			return true
		}
		seen[key] = true
		for i, branch := range c.branches {
			k := positions[i]
			if k < len(branch) {
				step := branch[k]
				var after LawSpecValue
				if !lsAllowed(func() { after, _ = lsStepModel(&m.commands[step.index], symbols, step.args, state) }) {
					return false
				}
				if !visit(lsAdvanced(positions, i), after) {
					return false
				}
			}
		}
		return true
	}
	return visit(make([]int, len(c.branches)), start)
}

func (m *lawSpecMachine) generateBranch(random *LawSpecSplitMix64, state LawSpecValue, length, size int64) []lawSpecModelStep {
	symbols := map[string]*LawSpecSymbol{}
	steps := []lawSpecModelStep{}
	for ; length > 0; length-- {
		index := int(random.Below(uint64(len(m.commands))))
		c := &m.commands[index]
		args := []LawSpecValue{}
		for _, d := range c.arguments {
			args = append(args, m.values.generate(d, random, size))
		}
		if !lsAllowed(func() { state, _ = lsStepModel(c, symbols, args, state) }) {
			continue
		}
		steps = append(steps, lawSpecModelStep{index, args})
	}
	return steps
}

func (m *lawSpecMachine) generateParallel(random *LawSpecSplitMix64, size int64, threads, branchLength int) lawSpecParallelCase {
	prefix := m.generateRun(random, int64(random.Below(4)), size)
	c := lawSpecParallelCase{prefix: prefix, branches: make([][]lawSpecModelStep, threads)}
	for i := range c.branches {
		c.branches[i] = []lawSpecModelStep{}
	}
	var state LawSpecValue
	if !lsAllowed(func() { state = m.simulateState(map[string]*LawSpecSymbol{}, prefix) }) {
		return c
	}
	for i := range c.branches {
		c.branches[i] = m.generateBranch(random, state, 1+int64(random.Below(uint64(branchLength))), size)
	}
	// Drop the last step of the longest branch (the first, among equals)
	// until every interleaving is allowed.
	for !m.parallelAllowed(c) {
		longest := 0
		for i := range c.branches {
			if len(c.branches[i]) > len(c.branches[longest]) {
				longest = i
			}
		}
		c.branches[longest] = c.branches[longest][:len(c.branches[longest])-1]
	}
	return c
}

func lsWithState(c *lawSpecModelCommand, args []LawSpecValue, state LawSpecValue) []LawSpecValue {
	full := append(append([]LawSpecValue{}, args[:c.state]...), state)
	return append(full, args[c.state:]...)
}

// lsPerturb is nothing, a yield, or a sleep of 10 or 100 microseconds.
func lsPerturb(random *LawSpecSplitMix64) {
	switch random.Below(4) {
	case 1:
		goruntime.Gosched()
	case 2:
		time.Sleep(10 * time.Microsecond)
	case 3:
		time.Sleep(100 * time.Microsecond)
	}
}

// executeParallel is what went wrong, or failed false when the history is
// linearizable.
func (m *lawSpecMachine) executeParallel(pc lawSpecParallelCase, shake uint64) (message string, failed bool) {
	symbols := map[string]*LawSpecSymbol{}
	var state LawSpecValue
	prefixFailure := func() (message string) {
		defer func() {
			if r := recover(); r != nil {
				message = fmt.Sprintf("the prefix raised panic: %v", r)
			}
		}()
		state = m.startRun(symbols, pc.prefix.start)
		for _, s := range pc.prefix.steps {
			c := &m.commands[s.index]
			c.run(symbols, lsWithState(c, s.args, state))
		}
		return ""
	}()
	if prefixFailure != "" {
		return prefixFailure, true
	}
	var clock int64
	var lock sync.Mutex
	history := make([][]lawSpecCall, len(pc.branches))
	errors := []string{}
	var group sync.WaitGroup
	for i := range pc.branches {
		history[i] = make([]lawSpecCall, len(pc.branches[i]))
		group.Add(1)
		go func(i int) {
			defer group.Done()
			own := map[string]*LawSpecSymbol{}
			random := &LawSpecSplitMix64{shake ^ (uint64(i+1) * 0x9E3779B97F4A7C15)}
			for k, s := range pc.branches[i] {
				c := &m.commands[s.index]
				full := lsWithState(c, s.args, state)
				lsPerturb(random)
				called := atomic.AddInt64(&clock, 1)
				result := func() (result LawSpecValue) {
					defer func() {
						if r := recover(); r != nil {
							lock.Lock()
							errors = append(errors, fmt.Sprintf("%s raised panic: %v", c.name, r))
							lock.Unlock()
							result = LawSpecValue{}
						}
					}()
					return c.run(own, full)
				}()
				history[i][k] = lawSpecCall{called, atomic.AddInt64(&clock, 1), result}
				lsPerturb(random)
			}
		}(i)
	}
	group.Wait()
	if len(errors) > 0 {
		return errors[0], true
	}
	expected := m.simulateState(symbols, pc.prefix)
	var final *LawSpecValue
	if m.abstract != nil {
		actual := m.abstract(symbols, []LawSpecValue{state})
		final = &actual
	}
	if m.linearizable(symbols, pc.branches, history, expected, final, state) {
		return "", false
	}
	observed := []string{}
	for i := range pc.branches {
		for k, s := range pc.branches[i] {
			observed = append(observed, fmt.Sprintf("%s: %s() returned %s", lsBranchName(i), m.commands[s.index].name, lsRender(history[i][k].result)))
		}
	}
	return "no order of the parallel calls agrees with the model (" + strings.Join(observed, "; ") + ")", true
}

func lsBranchName(i int) string {
	return string(rune('A' + i))
}

// linearizable is whether the history linearizes, with the final state and
// invariants the model gives. For a set or map whose every call touches one
// key, each key's calls are linearized separately (the keys are
// independent), one group after another in the order of their rendered keys;
// otherwise all calls at once.
func (m *lawSpecMachine) linearizable(symbols map[string]*LawSpecSymbol, branches [][]lawSpecModelStep, history [][]lawSpecCall, expected LawSpecValue, final *LawSpecValue, state LawSpecValue) bool {
	finish := func(model LawSpecValue) bool {
		if final != nil && lsCompareValues(*final, model) != 0 {
			return false
		}
		for i, kind := range m.invariantKinds {
			if i >= len(m.invariants) {
				break
			}
			subject := state
			if kind == "model" {
				subject = model
			}
			if !lsTruth(m.invariants[i](symbols, []LawSpecValue{subject})) {
				return false
			}
		}
		return true
	}
	if !m.perKey {
		return m.linearize(symbols, branches, history, expected, finish)
	}
	type group struct {
		branches [][]lawSpecModelStep
		history  [][]lawSpecCall
	}
	groups := map[string]*group{}
	keys := []string{}
	for i, branch := range branches {
		for k, step := range branch {
			key := lsRender(step.args[m.commands[step.index].key])
			g, ok := groups[key]
			if !ok {
				g = &group{make([][]lawSpecModelStep, len(branches)), make([][]lawSpecCall, len(branches))}
				groups[key] = g
				keys = append(keys, key)
			}
			g.branches[i] = append(g.branches[i], step)
			g.history[i] = append(g.history[i], history[i][k])
		}
	}
	sort.Strings(keys)
	model := expected
	for _, key := range keys {
		g := groups[key]
		var end LawSpecValue
		found := false
		record := func(state LawSpecValue) bool {
			if !found {
				end, found = state, true
			}
			return true
		}
		if !m.linearize(symbols, g.branches, g.history, model, record) {
			return false
		}
		model = end
	}
	return finish(model)
}

// linearize is a Wing-Gong search: linearize, next, a call no pending call
// on another thread returned before; memoized on positions and the model
// state. finish judges each complete order's final model state.
func (m *lawSpecMachine) linearize(symbols map[string]*LawSpecSymbol, branches [][]lawSpecModelStep, history [][]lawSpecCall, expected LawSpecValue, finish func(LawSpecValue) bool) bool {
	seen := map[string]bool{}
	var visit func(positions []int, model LawSpecValue) bool
	visit = func(positions []int, model LawSpecValue) bool {
		key := lsPositionsKey(positions, model)
		if seen[key] {
			return false
		}
		seen[key] = true
		done := true
		for i := range branches {
			if positions[i] < len(branches[i]) {
				done = false
			}
		}
		if done {
			return finish(model)
		}
		for i, branch := range branches {
			k := positions[i]
			if k == len(branch) {
				continue
			}
			called := history[i][k].called
			blocked := false
			for j := range branches {
				if j != i && positions[j] < len(branches[j]) && history[j][positions[j]].returned < called {
					blocked = true
					break
				}
			}
			if blocked {
				continue
			}
			step := branch[k]
			c := &m.commands[step.index]
			var after, wanted LawSpecValue
			if !lsAllowed(func() { after, wanted = lsStepModel(c, symbols, step.args, model) }) {
				continue
			}
			if !c.unit && lsCompareValues(history[i][k].result, wanted) != 0 {
				continue
			}
			if visit(lsAdvanced(positions, i), after) {
				return true
			}
		}
		return false
	}
	return visit(make([]int, len(branches)), expected)
}

func (m *lawSpecMachine) parallelFails(c lawSpecParallelCase, repeats int, shake uint64) (string, bool) {
	for attempt := 0; attempt < repeats; attempt++ {
		if message, failed := m.executeParallel(c, shake+uint64(attempt)); failed {
			return message, true
		}
	}
	return "", false
}

func (m *lawSpecMachine) shrinkParallel(pc lawSpecParallelCase, failure string, repeats, budget int, shake uint64) (lawSpecParallelCase, string) {
	for budget > 0 {
		candidates := []lawSpecParallelCase{}
		steps := pc.prefix.steps
		for k := range steps {
			kept := append(append([]lawSpecModelStep{}, steps[:k]...), steps[k+1:]...)
			candidates = append(candidates, lawSpecParallelCase{lawSpecModelRun{pc.prefix.start, kept}, pc.branches})
		}
		for i := range pc.branches {
			for k := range pc.branches[i] {
				shorter := append([][]lawSpecModelStep{}, pc.branches...)
				b := pc.branches[i]
				shorter[i] = append(append([]lawSpecModelStep{}, b[:k]...), b[k+1:]...)
				candidates = append(candidates, lawSpecParallelCase{pc.prefix, shorter})
			}
		}
		// Then smaller arguments, branch by branch, step by step.
		for i := range pc.branches {
			for k, s := range pc.branches[i] {
				c := &m.commands[s.index]
				for a := 0; a < len(c.arguments) && a < len(s.args); a++ {
					for _, candidate := range m.values.shrink(c.arguments[a], s.args[a]) {
						args := append([]LawSpecValue{}, s.args...)
						args[a] = candidate
						changed := append([][]lawSpecModelStep{}, pc.branches...)
						b := append([]lawSpecModelStep{}, pc.branches[i]...)
						b[k] = lawSpecModelStep{s.index, args}
						changed[i] = b
						candidates = append(candidates, lawSpecParallelCase{pc.prefix, changed})
					}
				}
			}
		}
		exhausted := true
		for _, candidate := range candidates {
			budget--
			if budget <= 0 {
				exhausted = false
				break
			}
			if !m.parallelAllowed(candidate) {
				continue
			}
			if message, failed := m.parallelFails(candidate, repeats, shake); failed {
				pc, failure, exhausted = candidate, message, false
				break
			}
		}
		if exhausted {
			break
		}
	}
	return pc, failure
}

func (m *lawSpecMachine) describeParallel(pc lawSpecParallelCase) string {
	describe := func(steps []lawSpecModelStep) string {
		parts := []string{}
		for _, s := range steps {
			args := make([]string, len(s.args))
			for j, a := range s.args {
				args[j] = lsRender(a)
			}
			parts = append(parts, m.commands[s.index].name+"("+strings.Join(args, ", ")+")")
		}
		if len(parts) == 0 {
			return "nothing"
		}
		return strings.Join(parts, "; ")
	}
	parts := make([]string, len(pc.branches))
	for i, b := range pc.branches {
		parts[i] = lsBranchName(i) + ": " + describe(b)
	}
	last := len(parts) - 1
	return fmt.Sprintf("%s, then %s and %s at the same time", m.describeRun(pc.prefix), strings.Join(parts[:last], ", "), parts[last])
}

// LawSpecCheckModelParallel checks a shared model's histories under
// concurrency (50 cases of 3 threads, each run 10 times, seeded from
// LAWSPEC_SEED); a failure is an error naming the smallest failing case
// found.
func LawSpecCheckModelParallel(model LawSpecModel) error {
	var seed uint64
	if text := os.Getenv("LAWSPEC_SEED"); text != "" {
		parsed, err := strconv.ParseUint(text, 10, 64)
		if err != nil {
			return fmt.Errorf("invalid LAWSPEC_SEED %q", text)
		}
		seed = parsed
	}
	return lsCheckModelParallel(model, 50, 10, 300, lawSpecParallelThreads, lawSpecParallelBranch, seed)
}

func lsCheckModelParallel(model LawSpecModel, cases, repeats, maxShrinks, threads, branchLength int, seed uint64) error {
	m := lsNewMachine(model)
	random := &LawSpecSplitMix64{seed ^ 0x5BD1E995}
	for n := 0; n < cases; n++ {
		c := m.generateParallel(random, int64(1+n%8), threads, branchLength)
		shake := random.Next()
		if failure, failed := m.parallelFails(c, repeats, shake); failed {
			c, failure = m.shrinkParallel(c, failure, max(2, repeats/2), maxShrinks, shake)
			return fmt.Errorf("model %s is not linearizable: %s: %s", m.name, m.describeParallel(c), failure)
		}
	}
	return nil
}
