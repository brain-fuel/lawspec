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
    case 'perform':
      return node.arguments;
    case 'calls':
      return node.arguments ?? [];
    case 'field':
      return [node.value];
    case 'update':
      return [node.value, node.field];
    case 'if':
      return [node.condition, node.then, node.else];
    case 'let':
      return [node.value, node.body];
    case 'handle':
      return [node.body];
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
      throw new Error(`Unrecognized expression node: ${JSON.stringify(unreachable)}`);
    }
  }
}

export function nodeFixtures(value: Expr, callback: PayloadPredicate): ExprNode[] {
  const payload: ExprNode = {kind: 'allPayloads', value, predicates: [callback]};
  const element: ExprNode = {
    kind: 'allElements', value, binder: callback.binder, predicate: callback.predicate,
  };
  children(payload);
  children(element);
  const remainingNodes: ExprNode[] = [
    {kind: 'field', constructor: 'Record', index: 0, value},
    {kind: 'update', constructor: 'Record', index: 0, value, field: value},
    {kind: 'if', condition: value, then: value, else: value},
    {kind: 'let', binder: callback.binder, value, body: value},
    {kind: 'perform', ability: 'Log', operation: 'write', arguments: [value]},
    {kind: 'handle', handling: 'catchFailure', ability: 'Fail', body: value},
    {kind: 'handle', handling: 'withHandler', ability: 'Log', handler: 'recording fakeLog', body: value},
    {kind: 'calls', ability: 'Log', operation: 'write', arguments: null},
    {kind: 'calls', ability: 'Log', operation: 'write', arguments: []},
  ];
  remainingNodes.forEach(children);
  // @ts-expect-error A spec handler name is required for withHandler.
  const missingHandler: ExprNode = {kind: 'handle', handling: 'withHandler', ability: 'Log', body: value};
  // @ts-expect-error A let binder has typed lexical identity, not just a name.
  const missingBinderType: ExprNode = {kind: 'let', binder: 'entry', value, body: value};
  // @ts-expect-error Calls without an argument filter use null explicitly.
  const missingCallArguments: ExprNode = {kind: 'calls', ability: 'Log', operation: 'write'};
  // @ts-expect-error Field positions are numeric indices.
  const malformedField: ExprNode = {kind: 'field', constructor: 'Record', index: 'value', value};
  void missingHandler; void missingBinderType; void missingCallArguments; void malformedField;
  // @ts-expect-error Callbacks require typed binder metadata.
  const malformed: PayloadPredicate = {binder: 'payload', predicate: value};
  void malformed;
  return [payload, element, ...remainingNodes];
}


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
