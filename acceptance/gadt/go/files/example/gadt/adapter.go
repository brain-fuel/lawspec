// User-owned LawSpec adapter.
package gadt

import "math/big"

// EvalNumber evaluates a number expression. Only number variants implement
// Expr[*LawSpecBigInt], so the switch needs no other cases.
func EvalNumber(value0 Expr[*LawSpecBigInt]) *LawSpecBigInt {
	switch e := value0.(type) {
	case ExprNumber:
		return e.Value
	case ExprPlus:
		return new(big.Int).Add(EvalNumber(e.Value.Left), EvalNumber(e.Value.Right))
	}
	panic("not an Expr[*LawSpecBigInt]")
}

// EvalTruth evaluates a Boolean expression.
func EvalTruth(value0 Expr[bool]) bool {
	switch e := value0.(type) {
	case ExprTruth:
		return e.Value
	case ExprSame:
		return EvalNumber(e.Value.Left).Cmp(EvalNumber(e.Value.Right)) == 0
	case ExprNegate:
		return !EvalTruth(e.Value)
	}
	panic("not an Expr[bool]")
}

// EvalPair evaluates both halves. Go cannot name a variant's existential
// types, so Both holds checked values that the generated codecs decode.
func EvalPair(value0 Expr[Pair[*LawSpecBigInt, bool]]) Pair[*LawSpecBigInt, bool] {
	both := value0.(ExprBoth[Pair[*LawSpecBigInt, bool]])
	schema := lawSpecDataSchemaRegistry()
	payload := lawSpecBothDetailsCodec(schema, 64, lsScalarCodec[*LawSpecBigInt](schema, 64, "Integer"), lsScalarCodec[bool](schema, 64, "Bool")).toNative(both.Value)

	return Pair[*LawSpecBigInt, bool]{
		First:  EvalNumber(payload.First),
		Second: EvalTruth(payload.Second),
	}
}

// Fold replaces an expression by the number it evaluates to.
func Fold(value0 Expr[*LawSpecBigInt]) Expr[*LawSpecBigInt] {
	return ExprNumber{Value: EvalNumber(value0)}
}

// Describe names the type a shown value holds, from its witness.
func Describe(value0 Shown) string {
	return value0.Witness
}
