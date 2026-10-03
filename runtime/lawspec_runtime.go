// Portable scalar arithmetic. No test framework dependencies.
package RUNTIME_PACKAGE

import (
	"fmt"
	"math"
	"math/big"
	"math/rand"
	"reflect"
	"strconv"
	"strings"
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
		result := attempt()
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

