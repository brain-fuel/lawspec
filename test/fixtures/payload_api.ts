import type {Expr, ExprNode, PayloadPredicate, DocumentaryReference, DocumentaryTarget, Law, DataTypeDeclaration, StructuralRecord} from '../../npm/index.js';

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


export function referencedTarget(reference: DocumentaryReference): DocumentaryTarget | null {
  switch (reference.kind) {
    case 'law':
    case 'function':
      return reference.target;
    case 'external':
      return null;
    default: {
      const unreachable: never = reference;
      return unreachable;
    }
  }
}
export function documentaryTargets(law: Law): DocumentaryTarget[] {
  return law.references.flatMap(reference => {
    if (typeof reference === 'string') return [];
    const target = referencedTarget(reference);
    return target ? [target] : [];
  });
}
// @ts-expect-error External references require a documentary resource.
const missingResource: DocumentaryReference = { kind: 'external', name: 'policy' };
void missingResource;

export function structuralRestrictions(declaration: DataTypeDeclaration): Expr[] {
  const structure: StructuralRecord | undefined = declaration.structure;
  if (!structure) return [];
  const kind: 'record' = structure.kind;
  const identity: string = structure.digest;
  const descriptor: string = structure.descriptor;
  void kind; void identity; void descriptor;
  return structure.fields.flatMap(field => field.predicates);
}
