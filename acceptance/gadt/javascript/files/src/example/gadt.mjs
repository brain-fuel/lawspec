// User-owned LawSpec adapter.
import * as data from '.././lawspec_data.mjs';

export function evalNumber(value0) {
  if (value0 instanceof data.ExprNumber) return value0.value;
  return evalNumber(value0.left) + evalNumber(value0.right);
}

export function evalTruth(value0) {
  if (value0 instanceof data.ExprTruth) return value0.value;
  if (value0 instanceof data.ExprSame) {
    return evalNumber(value0.left) === evalNumber(value0.right);
  }
  return !evalTruth(value0.operand);
}

export function evalPair(value0) {
  return new data.Pair(evalNumber(value0.first), evalTruth(value0.second));
}

export function fold(value0) {
  return new data.ExprNumber(evalNumber(value0));
}

export function describe(value0) {
  return value0.witness;
}
