// User-owned LawSpec adapter.
import * as data from '.././lawspec_data.js';

// Within Expr<bigint> only the number cases exist, so narrowing needs no casts.
export function evalNumber(value0: data.Expr<bigint>): bigint {
  if (value0 instanceof data.ExprNumber) return value0.value;
  return evalNumber(value0.left) + evalNumber(value0.right);
}

export function evalTruth(value0: data.Expr<boolean>): boolean {
  if (value0 instanceof data.ExprTruth) return value0.value;
  if (value0 instanceof data.ExprSame) {
    return evalNumber(value0.left) === evalNumber(value0.right);
  }
  return !evalTruth(value0.operand);
}

export function evalPair(value0: data.Expr<data.Pair<bigint, boolean>>): data.Pair<bigint, boolean> {
  return new data.Pair(evalNumber(value0.first), evalTruth(value0.second));
}

export function fold(value0: data.Expr<bigint>): data.Expr<bigint> {
  return new data.ExprNumber(evalNumber(value0));
}
