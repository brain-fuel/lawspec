import type {Expr, ExprNode, PayloadPredicate, DocumentaryReference, DocumentaryTarget, Law, DataTypeDeclaration, StructuralRecord, DeclarationSource, Unit, Result, CheckRequest, ObligationEvidence, NativeFieldBinding, ModelAnswerCheck} from '../../npm/index.js';

export function authoredNames(unit: Unit): string[] {
  return unit.declarations.flatMap(declaration => {
    const source: DeclarationSource | undefined = declaration.source;
    if (!source) return [];
    const canonical: string | undefined = source.canonicalName;
    return [canonical ?? `${source.unit}.${source.name}`];
  });
}

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
    case 'searchElements':
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
    {kind: 'searchElements', universal: true, value, binder: callback.binder, predicate: callback.predicate},
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
  const positions: string[] | undefined = structure.positions;
  void positions;
  const identity: string = structure.digest;
  const descriptor: string = structure.descriptor;
  void kind; void identity; void descriptor;
  return structure.fields.flatMap(field => field.predicates);
}

export function verificationSelection(result: Result): string | undefined {
  if (!result.verification) return undefined;
  const intrinsic: true = result.verification.intrinsicDefinitionChecks;
  const selected: 'no-selected-checks' | 'selected-checks' = result.verification.selection;
  void intrinsic;
  return selected;
}

const nativeLeaf: NativeFieldBinding = {field:'value',path:['first'],argument:0,native:'head'};
// @ts-expect-error A path needs an explicit native argument position.
const missingPosition: NativeFieldBinding = {field:'value',path:['first'],native:'head'};
// @ts-expect-error A native argument position needs an explicit structural path.
const missingPath: NativeFieldBinding = {field:'value',argument:0,native:'head'};
void nativeLeaf; void missingPosition; void missingPath;

// @ts-expect-error ordinary clients cannot select a legacy schema
const oldSchema: CheckRequest = {languageProfile: '1.0-rc.2', sources: [], schemaVersion: 4};
// @ts-expect-error the canonical profile must be explicit
const missingProfile: CheckRequest = {sources: []};
void oldSchema; void missingProfile;

// Public consumers distinguish exact model slots from law test families and
// retain the native scope when grouping completion reports.
export function nativeModelSlots(result: Result): string[] {
  return (result.tests ?? []).filter(entry => entry.kind === 'model')
    .map(entry => `${entry.file}:${entry.scope ?? entry.unit}:${entry.name}`);
}

export function nativeObservationScopes(result: Result): string[] {
  return (result.evidence ?? []).flatMap(item => (item.nativeEvidence?.observations ?? []).map(row => {
    const seed: number | string | undefined = row.attempt?.seed;
    const finiteCases: number | undefined = row.coverage?.cases;
    return `${item.declaration}:${row.target}:${row.freshness}:${row.outcome}:${seed}:${finiteCases}`;
  }));
}

// Model SAT answers are accepted only after current evaluator replay. These
// structural checks also let the host retry an obsolete cached model.
export function checkedModelAnswers(result: Result): {fingerprint: string; confirmed: boolean; reason: string}[] {
  return (result.modelChecks ?? []).map((check: ModelAnswerCheck) => {
    switch (check.status) {
      case 'confirmed':
        return {fingerprint: check.fingerprint, confirmed: true, reason: check.reason};
      case 'model-not-confirmed':
        return {fingerprint: check.fingerprint, confirmed: false, reason: check.reason};
      default: {
        const impossible: never = check.status;
        throw new Error(`Unrecognized model answer check: ${impossible}`);
      }
    }
  });
}
