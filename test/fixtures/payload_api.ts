import type {Expr, ExprNode, PayloadPredicate} from '../../npm/index.js';

// Every published node must be traversable without an unchecked cast.
export function children(node: ExprNode): Expr[] {
  switch (node.kind) {
    case 'constant':
    case 'local':
      return [];
    case 'construct':
    case 'call':
    case 'helper':
      return node.arguments;
    case 'match':
      return [node.value, ...node.cases.map(branch => branch.body)];
    case 'allElements':
      return [node.value, node.predicate];
    case 'allPayloads':
      return [node.value, ...node.predicates.map(callback => callback.predicate)];
    case 'binary':
    case 'shortCircuit':
      return [node.left, node.right];
    case 'unary':
    case 'convert':
      return [node.argument];
    default: {
      const unreachable: never = node;
      return unreachable;
    }
  }
}

declare const value: Expr;
declare const callback: PayloadPredicate;
const payload: ExprNode = {kind: 'allPayloads', value, predicates: [callback]};
const element: ExprNode = {
  kind: 'allElements', value, binder: callback.binder, predicate: callback.predicate,
};
children(payload);
children(element);
// @ts-expect-error Callbacks require typed binder metadata.
const malformed: PayloadPredicate = {binder: 'payload', predicate: value};
void malformed;
