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
type lawSpecSymbol struct{ description string }
type lawSpecPresence struct{ value *LawSpecValue }

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
		s = &lawSpecSymbol{d}
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
			_, valid = v.Data.(lawSpecDecimal)
		case "Rational":
			_, valid = v.Data.(*big.Rat)
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
func lsHelper(n string, args []LawSpecValue, bits int) LawSpecValue {
    switch n {
    case "checked": return lsBool(true)
    case "length": return lsInteger("Integer",strconv.Itoa(len(args[0].Data.([]int))))
    case "isPresent": return lsBool(args[0].Data.(lawSpecPresence).value != nil)
    case "presentValue": p:=args[0].Data.(lawSpecPresence).value; if p==nil {panic("absent presence value")}; return *p
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
	case "quot", "rem":
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
		return LawSpecValue{t, &lawSpecSymbol{"same"}}
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
	if t == "IntSize" || t == "UIntSize" || t == "UIntPtr" {
		if strconv.IntSize != bits {
			panic("machineBits does not match native architecture")
		}
	}
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
	if t == "IntSize" || t == "UIntSize" || t == "UIntPtr" {
		if strconv.IntSize != bits {
			panic("machineBits does not match native architecture")
		}
	}
	var data any = value
	if lsIntegerType(t) {
		rv := reflect.ValueOf(value)
		switch rv.Kind() {
		case reflect.Int, reflect.Int8, reflect.Int16, reflect.Int32, reflect.Int64:
			data = big.NewInt(rv.Int())
		case reflect.Uint, reflect.Uint8, reflect.Uint16, reflect.Uint32, reflect.Uint64, reflect.Uintptr:
			data = new(big.Int).SetUint64(rv.Uint())
		default:
			switch n:=value.(type) {case *big.Int: if n==nil {panic("invalid Integer representation")}; data=new(big.Int).Set(n); case big.Int: data=new(big.Int).Set(&n); default: panic("invalid Integer representation")}
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

type lawSpecBound struct { op string; value LawSpecValue }
type lawSpecDomain struct { candidates func([]LawSpecValue,int) []LawSpecValue; accept func([]LawSpecValue) bool }
func lsFloor(r *big.Rat) *big.Int { q,rem:=new(big.Int).QuoRem(r.Num(),r.Denom(),new(big.Int));if rem.Sign()<0 {q.Sub(q,big.NewInt(1))};return q }
func lsCeil(r *big.Rat) *big.Int { return new(big.Int).Neg(lsFloor(new(big.Rat).Neg(r))) }
func lsDomainCandidates(t string,seed,bits int,restrictions []lawSpecBound,hints []LawSpecValue) []LawSpecValue {
 values:=[]LawSpecValue{};for _,hint:=range hints {func(){defer func(){recover()}();values=append(values,lsConvert(t,hint,bits))}()}
 if lsIntegerType(t) {
  var lo,hi *big.Int
  if t=="BigUInt" {lo=big.NewInt(0)} else if t!="Integer" && t!="BigInt" {w:=bits;if t!="IntSize"&&t!="UIntSize"&&t!="UIntPtr" {w,_=strconv.Atoi(strings.TrimLeft(t,"UInt"))};if strings.HasPrefix(t,"Int") {hi=new(big.Int).Lsh(big.NewInt(1),uint(w-1));lo=new(big.Int).Neg(new(big.Int).Set(hi));hi.Sub(hi,big.NewInt(1))}else{lo=big.NewInt(0);hi=new(big.Int).Sub(new(big.Int).Lsh(big.NewInt(1),uint(w)),big.NewInt(1))}}
  for _,b:=range restrictions {r:=lsRatio(b.value)
   if b.op==">"||b.op==">="||b.op=="==" {v:=lsCeil(r);if b.op==">" {v.Add(lsFloor(r),big.NewInt(1))};if lo==nil||v.Cmp(lo)>0 {lo=v}}
   if b.op=="<"||b.op=="<="||b.op=="==" {v:=lsFloor(r);if b.op=="<" {v.Sub(lsCeil(r),big.NewInt(1))};if hi==nil||v.Cmp(hi)<0 {hi=v}}
  }
  if lo!=nil&&hi!=nil&&lo.Cmp(hi)>0{return nil}
  lower,upper:=lo,hi
  if lower==nil {lower=new(big.Int).Neg(new(big.Int).Lsh(big.NewInt(1),256));if hi!=nil&&hi.Sign()<0 {lower.Add(lower,hi)}}
  if upper==nil {upper=new(big.Int).Lsh(big.NewInt(1),256);if lo!=nil&&lo.Sign()>0 {upper.Add(upper,lo)}}
  ns:=[]*big.Int{lower,upper,big.NewInt(0),big.NewInt(1),big.NewInt(-1),new(big.Int).Add(lower,big.NewInt(1)),new(big.Int).Sub(upper,big.NewInt(1))}
  random:=rand.New(rand.NewSource(int64(seed)));width:=new(big.Int).Add(new(big.Int).Sub(upper,lower),big.NewInt(1))
  for j:=0;j<8;j++ {ns=append(ns,new(big.Int).Add(lower,new(big.Int).Rand(random,width)))}
  for _,n:=range ns {values=append(values,LawSpecValue{t,n})}
  filtered:=[]LawSpecValue{};for _,v:=range values {if lsIntegerType(v.Type) {n:=v.Data.(*big.Int);if n.Cmp(lower)>=0&&n.Cmp(upper)<=0 {filtered=append(filtered,lsConvert(t,v,bits))}}};values=filtered
 } else {for j:=0;j<8;j++ {values=append(values,lsSample(t,seed+j*7919,bits))}}
 if len(values)>0 {offset:=((seed%len(values))+len(values))%len(values);values=append(append([]LawSpecValue{},values[offset:]...),values[:offset]...)}
 return values
}
func lsGenerateTuple(domains []lawSpecDomain,seed,attempts int,prefix []LawSpecValue) ([]LawSpecValue,bool) {
 used:=0;lastPrefix:=prefix
 var search func([]LawSpecValue)([]LawSpecValue,bool)
 search=func(values []LawSpecValue)([]LawSpecValue,bool){lastPrefix=values;if len(values)==len(domains){return values,true};if used>=attempts{return nil,false};used++
  d:=domains[len(values)];for _,v:=range d.candidates(values,seed+used*7919){if used>=attempts{break};used++;next:=append(append([]LawSpecValue{},values...),v);if d.accept(next){if result,ok:=search(next);ok{return result,true}}};return nil,false}
 for used<attempts {if result,ok:=search(append([]LawSpecValue{},prefix...));ok{return result,true}}
 return lastPrefix,false
}
func lsRequireContract(condition bool,context string){if !condition{panic(context)}}
func lsContract(context string,condition bool,result LawSpecValue) LawSpecValue {lsRequireContract(condition,context);return result}
func lsCapture(check func([]LawSpecValue),values []LawSpecValue)(failure any){defer func(){failure=recover()}();check(values);return nil}
func lsRefinedCase(domains []lawSpecDomain,seed,attempts,shrinks int,check func([]LawSpecValue),context string) {
 values,ok:=lsGenerateTuple(domains,seed,attempts,nil);if !ok{panic(fmt.Sprintf("%s: refinement-generation-exhausted after %d attempts; prefix=%v; seed=%d",context,attempts,values,seed))}
 if original:=lsCapture(check,values);original!=nil {best,budget:=values,shrinks
  for i:=range best {value:=best[i];candidates:=domains[i].candidates(best[:i],0)
   if lsIntegerType(value.Type){initial:=value.Data.(*big.Int);candidates=append([]LawSpecValue{{value.Type,big.NewInt(0)},{value.Type,big.NewInt(int64(initial.Sign()))}},candidates...);for n:=new(big.Int).Quo(initial,big.NewInt(2));new(big.Int).Abs(n).Cmp(big.NewInt(1))>0;n=new(big.Int).Quo(n,big.NewInt(2)){candidates=append(candidates,LawSpecValue{value.Type,n})}}
   for _,candidate:=range candidates {if budget<=0{break};budget--;if lsComplexity(candidate).Cmp(lsComplexity(best[i]))>=0{continue};prefix:=append(append([]LawSpecValue{},best[:i]...),candidate);if !domains[i].accept(prefix){continue};trial,ok:=lsGenerateTuple(domains,seed,min(attempts,100),prefix);if ok&&lsCapture(check,trial)!=nil{best=trial}}
  };panic(fmt.Sprintf("%s: %v; refined counterexample=%v; seed=%d",context,original,best,seed))
 }
}
func lsAssert(context string,actual,expected func()LawSpecValue){defer func(){if err:=recover();err!=nil{panic(fmt.Sprintf("%s: %v",context,err))}}();a,b:=actual(),expected();if !lsEqual(a,b){panic(fmt.Sprintf("%s | actual=%v expected=%v",context,a,b))}}

func lsComplexity(v LawSpecValue)*big.Int {
 switch x:=v.Data.(type){
 case *big.Int:return new(big.Int).Abs(x)
 case []int:return big.NewInt(int64(len(x)))
 case lawSpecPresence:if x.value==nil{return big.NewInt(0)};return new(big.Int).Add(big.NewInt(1),lsComplexity(*x.value))
 case bool:if x{return big.NewInt(1)};return big.NewInt(0)
 case float64:return new(big.Int).SetUint64(math.Float64bits(math.Abs(x)))
 case complex128:return new(big.Int).Add(lsComplexity(LawSpecValue{"Float64",real(x)}),lsComplexity(LawSpecValue{"Float64",imag(x)}))
 case int:return big.NewInt(int64(x))
 }
 if lsExactType(v.Type){r:=lsRatio(v);return new(big.Int).Sub(new(big.Int).Add(new(big.Int).Abs(r.Num()),r.Denom()),big.NewInt(1))}
 if v.Data==nil{return big.NewInt(0)};return big.NewInt(1)
}
