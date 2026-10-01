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
		return new(big.Int).Add(EvalNumber(e.Left), EvalNumber(e.Right))
	}
	panic("not an Expr[*LawSpecBigInt]")
}

// EvalTruth evaluates a Boolean expression.
func EvalTruth(value0 Expr[bool]) bool {
	switch e := value0.(type) {
	case ExprTruth:
		return e.Value
	case ExprSame:
		return EvalNumber(e.Left).Cmp(EvalNumber(e.Right)) == 0
	case ExprNegate:
		return !EvalTruth(e.Operand)
	}
	panic("not an Expr[bool]")
}

// EvalPair evaluates both halves. Go cannot name a variant's existential
// types, so Both holds checked values that the generated codecs decode.
func EvalPair(value0 Expr[Pair[*LawSpecBigInt, bool]]) Pair[*LawSpecBigInt, bool] {
	both := value0.(ExprBoth[Pair[*LawSpecBigInt, bool]])
	schema := lawSpecDataSchemaRegistry()
	numbers := lawSpecExprCodec(schema, 64, lsScalarCodec[*LawSpecBigInt](schema, 64, "BigInt"))
	truths := lawSpecExprCodec(schema, 64, lsScalarCodec[bool](schema, 64, "Bool"))
	return Pair[*LawSpecBigInt, bool]{
		First:  EvalNumber(numbers.toNative(both.First)),
		Second: EvalTruth(truths.toNative(both.Second)),
	}
}

// Fold replaces an expression by the number it evaluates to.
func Fold(value0 Expr[*LawSpecBigInt]) Expr[*LawSpecBigInt] {
	return ExprNumber{Value: EvalNumber(value0)}
}
