// All presentations read the same typed law and its evidence. No view parses
// business wording or changes an obligation.
import { createTypePresentation } from './typed-presentation.mjs';

export const explanationViews = ['developer', 'business', 'formal', 'evidence'];
const presentationProposition = ({ typeName, expressionText }, inputs) => function proposition(assertion, business = false, scope = inputs) {
  const term = expression => expressionText(expression, scope);
  const recurse = (body, wording = business) => proposition(body, wording, scope);
  switch (assertion.kind) {
    case 'equal': return `${term(assertion.left)} ${business ? 'must be' : '='} ${term(assertion.right)}`;
    case 'implies': return business
      ? `If ${term(assertion.guard)}, then ${recurse(assertion.body, true)}`
      : `(${term(assertion.guard)}) implies (${recurse(assertion.body)})`;
    case 'all': return assertion.items.map(a => `(${recurse(a)})`).join(' and ');
    case 'not': {
      // The compiler's ordinary negation/conjunction representation also
      // expresses disjunction and implications with proposition premises.
      const items = assertion.body.kind === 'all' ? assertion.body.items : [];
      if (items.length > 1 && items.every(item => item.kind === 'not'))
        return items.map(item => `(${recurse(item.body)})`).join(' or ');
      if (items.length === 2 && items[1].kind === 'not') return business
        ? `If (${recurse(items[0], true)}), then (${recurse(items[1].body, true)})`
        : `(${recurse(items[0])}) implies (${recurse(items[1].body)})`;
      return business && assertion.body.kind === 'exists'
        ? recurse(assertion.body, true).replace(/^There must exist/, 'There must not exist')
        : `${business ? 'Must not' : 'not'} (${recurse(assertion.body, false)})`;
    }
    case 'forall':
    case 'exists': {
      const universal = assertion.kind === 'forall';
      const binder = `${assertion.binder.name} of type ${typeName(assertion.binder.type)}`;
      const nested = new Map([...scope, [assertion.binder.id, assertion.binder.name]]);
      const restrictions = assertion.predicates.map(p => expressionText(p, nested));
      const restricted = restrictions.length ? ` where ${restrictions.join(' and ')}` : '';
      if (business) return `${universal ? 'For every' : 'There must exist'} ${binder}${restricted}, ${proposition(assertion.body, true, nested)}`;
      return `${universal ? 'for all' : 'there exists'} (${binder}${restricted}) ${universal ? '=>' : 'such that'}\n${proposition(assertion.body, false, nested)}\nend`;
    }
    default: throw new Error(`Unsupported typed assertion ${assertion.kind}`);
  }
};
export function explainLaw(law, result, view = 'developer') {
  if (!explanationViews.includes(view)) throw new Error(`Choose --view ${explanationViews.join('|')}`);
  const presentation = createTypePresentation(result);
  const { typeName, expressionText, valueText } = presentation;
  const examples = law.examples ?? [];
  const scope = new Map(law.inputs.map(input => [input.id, input.name]));
  const proposition = presentationProposition(presentation, scope);
  const evidence = (result.evidence ?? []).filter(e => e.declaration === law.id);
  const quantifiers = law.inputs.map(input => `${input.name} of type ${typeName(input.type)}`);
  const restrictions = law.inputs.flatMap(input => input.predicates.map(p => expressionText(p, scope)));
  const metadata = law.metadata ?? {};
  const references = law.references ?? [];
  const witnesses = law.harness?.witnesses ?? [];
  const searches = law.harness?.searches ?? [];
  const strategies = [
    ...witnesses.map(witness => `Configured witness (not completed evidence): definition.${witness.path.join('.')} = ${expressionText(witness.expression, scope)}`),
    ...searches.map(search => `Configured search (not completed evidence): definition.${search.path.join('.')} uses ${search.strategy}`),
  ];
  const documentary = [metadata.id === undefined ? '' : `Requirement: ${metadata.id}`,
    metadata.owner === undefined ? '' : `Owner: ${metadata.owner}`,
    ...references.map(reference => `Reference: ${referenceText(reference)}`)].filter(Boolean);
  let text;
  if (view === 'evidence') text = evidence.length
    ? evidence.map(e => `${e.status.toUpperCase()}: ${e.reason}`+(e.nativeEvidence?'\n'+nativeEvidenceText(e):'')).join('\n')
    : 'No completed evidence has been supplied for this law.';
  else if (view === 'business') text = [...documentary, law.description,
    quantifiers.length ? `For every ${quantifiers.join(' and ')}` : '',
    restrictions.length ? `When ${restrictions.join(' and ')}` : '',
    proposition(law.assertion, true), law.rationale ? `Reason: ${law.rationale}` : ''].filter(Boolean).join('\n');
  else if (view === 'formal') text = [quantifiers.length ? `for all (${quantifiers.join(') (')}) =>` : '',
    restrictions.length ? `(${restrictions.join(' and ')}) implies` : '',
    proposition(law.assertion), ...(quantifiers.length ? ['end'] : [])].filter(Boolean).join('\n');
  else text = [law.id, ...documentary, ...law.trace, ...strategies,
    ...(quantifiers.length ? [`Inputs: ${quantifiers.join('; ')}`] : []),
    ...(restrictions.length ? [`Restrictions: ${restrictions.join(' and ')}`] : []), proposition(law.assertion),
    `Source: ${law.location.file}:${law.location.line}:${law.location.column}`,
    `Examples: ${examples.length}`,
    ...examples.flatMap(example => {
      const locals = new Map([...scope, ...example.bindings.map(binding => [binding.id, binding.name])]);
      return [`example ${JSON.stringify(example.name)}`,
        ...example.bindings.map(binding => `  ${binding.name} = ${valueText(binding.value, locals)}`),
        ...example.expectations.map(expectation => `  expect ${proposition(expectation, false, locals)}`)];
    })].join('\n');
  if(view==='developer')for(const item of evidence)if(item.nativeEvidence)text+='\n'+nativeEvidenceText(item);
  if (view === 'evidence' && strategies.length) text += '\n' + strategies.join('\n');
  return { view, law: law.id, metadata, references, witnesses, searches, examples, inputs: law.inputs, assertion: law.assertion, evidence, text };
}
function referenceText(reference) {
  if (typeof reference === 'string') return reference;
  if (reference.kind === 'external') return `${reference.name ? `${reference.name}: ` : ''}${reference.resource}`;
  const selector = reference.selector;
  const section = selector?.kind === 'named-reference' ? ` references.${selector.name}` : selector ? ` ${selector.kind}` : '';
  const raw = reference.target.name;
  // Built-in laws retain legacy source names internally; present their
  // canonical phrase spelling just as ordinary authored names are presented.
  const name = raw.startsWith('"|') || /^\p{L}[\p{L}\p{N}_]*$/u.test(raw)
    ? raw : `"|${raw.replace(/[\\|]/g, '\\$&')}|`;
  return `ref ${reference.kind} ${reference.target.unit}.${name}${section}`;
}

export function nativeEvidenceText(item){
  if(!item.nativeEvidence)return '';
  const summary=item.nativeEvidence;
  return [`Native conformance: ${summary.status}; search completeness: ${summary.searchCompleteness}`,
    ...summary.observations.map(row=>`${row.target} (${row.root}): ${row.outcome}; ${row.freshness}`+
      (row.attempt?`; seed ${row.attempt.seed}; ${row.attempt.at}`:'')+`; ${row.reason}`),
    ...summary.observations.flatMap(row=>(row.attempt?.tests??[]).filter(test=>test.status==='failed')
      .map(test=>`${test.name}: ${test.reason??test.failure??test.message??'native test failed'}`)),
    ...summary.observations.filter(row=>row.attempt?.invocation.output)
      .map(row=>'Native invocation output (scoped to that invocation):\n'+row.attempt.invocation.output)].join('\n');
}
