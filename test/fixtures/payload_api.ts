import type {Expr, ExprNode, PayloadPredicate, DocumentaryReference, DocumentaryTarget, Law, DataTypeDeclaration, StructuralRecord, DeclarationSource, Unit, Result, MigrationSemanticSnapshot, MigrationInputDomain, CheckRequest, MigrationComparisonRequest, MigrationPayloadComparison} from '../../npm/index.js';

export function migrationDigests(result: Result): string[] {
  const snapshot: MigrationSemanticSnapshot | undefined = result.migrationSemantics;
  if (!snapshot || snapshot.status === 'unavailable') return [];
  const version: 1 = snapshot.version;
  const algorithm: 'sha256' = snapshot.algorithm;
  const machineBits: 32 | 64 = snapshot.machineBits;
  const policy: ('nonempty' | 'universal')[] = snapshot.domainPolicies.map(item => item.policy);
  void version; void algorithm; void machineBits; void policy;
  const templates = snapshot.sourceTemplates;
  const sourceDigests = templates?.status === 'available'
    ? [templates.declarationsDigest, templates.definitionTemplatesDigest, templates.lawTemplatesDigest,
      templates.lawBodiesDigest, ...templates.definitions.map(item => item.digest),
      ...templates.laws.map(item => item.comparisonId)] : [];
  const inputDomains = snapshot.inputDomains;
  const domainDigests = inputDomains?.status === 'available'
    ? inputDomains.domains.map(domain => {
      if (domain.status === 'inhabited') {
        const values = domain.witness.map(binding => binding.value);
        void values;
      } else if (domain.status === 'empty') {
        const complete: true = domain.complete;
        void complete;
        // @ts-expect-error A complete empty domain has no fabricated witness.
        void domain.witness;
      } else {
        const complete: false = domain.complete;
        const reason: string = domain.reason;
        void complete; void reason;
      }
      return domain.domainDigest;
    }) : [];
  return [snapshot.programDigest, snapshot.definitionPlaneDigest, snapshot.lawBodiesDigest,
    ...sourceDigests,
    ...domainDigests,
    ...snapshot.definitions.map(item => item.comparisonId + ':' + item.digest),
    ...snapshot.contracts.map(item => item.digest), ...snapshot.dataTypes.map(item => item.digest)];
}

const captureRequest: CheckRequest = {schemaVersion: 5, languageProfile: '1.0-rc.1', sources: [], migrationSnapshot: true};
// @ts-expect-error Snapshot capture requires an actual Boolean switch.
const malformedCapture: CheckRequest = {sources: [], migrationSnapshot: 'yes'};
// @ts-expect-error Unavailable snapshots cannot claim matching concrete Core.
const malformedSnapshot: MigrationSemanticSnapshot = {status: 'unavailable', programDigest: 'digest'};
void captureRequest; void malformedCapture; void malformedSnapshot;
// @ts-expect-error An inhabited domain requires actual typed input witnesses.
const missingInputWitness: MigrationInputDomain = {status: 'inhabited'};
void missingInputWitness;

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

export function payloadFields(result: Result): string[] {
  const value: MigrationPayloadComparison | undefined = result.migrationComparison;
  if (!value || value.status === 'unavailable') return [];
  const validated: false = value.validated;
  const status: 'not-established' = value.executableTransport.status;
  const dependencyStatus: 'not-established' = value.dependencyBehavior.status;
  void validated; void status; void dependencyStatus;
  return value.payloadShapes.changes.flatMap(change => {
    if (change.status === 'not-established') return [change.reason];
    return change.constructors.flatMap(constructor => {
      if (constructor.kind === 'unchanged') return [];
      if (constructor.kind === 'record-payload') {
        const identity: string = constructor.recordType;
        void identity;
      }
      return constructor.fields.map(field => field.label + ':' + field.fromIndex + '->' + field.toIndex);
    });
  });
}
const comparisonRequest: MigrationComparisonRequest = {schemaVersion: 5, languageProfile: '1.0-rc.1', from: '0.24',
  sources: [], migrated: {languageProfile: '1.0-rc.1', sources: []}};
// @ts-expect-error Each input requires an explicit profile; the legacy input cannot implicitly choose it for the canonical input.
const missingComparisonProfile: MigrationComparisonRequest = {...comparisonRequest, migrated: {sources: []}};
// @ts-expect-error The migrated input cannot request the old grammar schema.
const wrongComparisonSchema: MigrationComparisonRequest = {...comparisonRequest, migrated: {languageProfile: '1.0-rc.1', sources: [], schemaVersion: 4}};
// @ts-expect-error Unavailable comparisons cannot manufacture payload matches.
const fabricatedComparison: MigrationPayloadComparison = {status: 'unavailable', payloadShapes: {status: 'matched'}};
void comparisonRequest; void missingComparisonProfile; void wrongComparisonSchema; void fabricatedComparison;
