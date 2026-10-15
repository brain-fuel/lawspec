// Generated from templates/npm/explain.mjs by lawspec-dev generate. Do not edit.
// All presentations read the same typed law and its evidence. No view parses
// business wording or changes an obligation.
export const explanationViews = ['developer', 'business', 'formal', 'evidence'];
const authoringTypeName = name => ({ BigUInt: 'Whole', BigInt: 'Integer', Natural: 'Whole' })[name] ?? name.split('::type::').at(-1);
const typeName = type => type.kind === 'constructor'
  ? authoringTypeName(type.name) + (type.arguments.length ? ' ' + type.arguments.map(a => a.kind === 'type' ? typeName(a.type) : a.value ?? a.id).join(' ') : '')
  : type.kind === 'function' ? `(${typeName(type.parameter)} -> ${typeName(type.result)})` : type.id;
function proposition(assertion, business = false) {
  switch (assertion.kind) {
    case 'equal': return `${assertion.left.text} ${business ? 'must be' : '='} ${assertion.right.text}`;
    case 'implies': return business
      ? `If ${assertion.guard.text}, then ${proposition(assertion.body, true)}`
      : `(${assertion.guard.text}) implies (${proposition(assertion.body)})`;
    case 'all': return assertion.items.map(a => `(${proposition(a, business)})`).join(' and ');
    case 'not': {
      // The compiler's ordinary negation/conjunction representation also
      // expresses disjunction and implications with proposition premises.
      const items = assertion.body.kind === 'all' ? assertion.body.items : [];
      if (items.length > 1 && items.every(item => item.kind === 'not'))
        return items.map(item => `(${proposition(item.body, business)})`).join(' or ');
      if (items.length === 2 && items[1].kind === 'not') return business
        ? `If (${proposition(items[0], true)}), then (${proposition(items[1].body, true)})`
        : `(${proposition(items[0])}) implies (${proposition(items[1].body)})`;
      return business && assertion.body.kind === 'exists'
        ? proposition(assertion.body, true).replace(/^There must exist/, 'There must not exist')
        : `${business ? 'Must not' : 'not'} (${proposition(assertion.body)})`;
    }
    case 'forall':
    case 'exists': {
      const universal = assertion.kind === 'forall';
      const binder = `${assertion.binder.name} of type ${typeName(assertion.binder.type)}`;
      const restrictions = assertion.predicates.map(p => p.text);
      const restricted = restrictions.length ? ` where ${restrictions.join(' and ')}` : '';
      if (business) return `${universal ? 'For every' : 'There must exist'} ${binder}${restricted}, ${proposition(assertion.body, true)}`;
      return `${universal ? 'for all' : 'there exists'} (${binder}${restricted}) ${universal ? '=>' : 'such that'}\n${proposition(assertion.body)}\nend`;
    }
    default: throw new Error(`Unsupported typed assertion ${assertion.kind}`);
  }
}
export function explainLaw(law, result, view = 'developer') {
  if (!explanationViews.includes(view)) throw new Error(`Choose --view ${explanationViews.join('|')}`);
  const evidence = (result.evidence ?? []).filter(e => e.declaration === law.id);
  const quantifiers = law.inputs.map(input => `${input.name} of type ${typeName(input.type)}`);
  const restrictions = law.inputs.flatMap(input => input.predicates.map(p => p.text));
  const metadata = law.metadata ?? {};
  const references = law.references ?? [];
  const witnesses = law.harness?.witnesses ?? [];
  const searches = law.harness?.searches ?? [];
  const strategies = [
    ...witnesses.map(witness => `Configured witness (not completed evidence): definition.${witness.path.join('.')} = ${witness.expression.text}`),
    ...searches.map(search => `Configured search (not completed evidence): definition.${search.path.join('.')} uses ${search.strategy}`),
  ];
  const documentary = [metadata.id === undefined ? '' : `Requirement: ${metadata.id}`,
    metadata.owner === undefined ? '' : `Owner: ${metadata.owner}`,
    ...references.map(reference => `Reference: ${referenceText(reference)}`)].filter(Boolean);
  let text;
  if (view === 'evidence') text = evidence.length
    ? evidence.map(e => `${e.status.toUpperCase()}: ${e.reason}`).join('\n')
    : 'No completed evidence has been supplied for this law.';
  else if (view === 'business') text = [...documentary, law.description,
    quantifiers.length ? `For every ${quantifiers.join(' and ')}` : '',
    restrictions.length ? `When ${restrictions.join(' and ')}` : '',
    proposition(law.assertion, true), law.rationale ? `Reason: ${law.rationale}` : ''].filter(Boolean).join('\n');
  else if (view === 'formal') text = [quantifiers.length ? `for all (${quantifiers.join(') (')}) =>` : '',
    restrictions.length ? `(${restrictions.join(' and ')}) implies` : '',
    proposition(law.assertion), ...(quantifiers.length ? ['end'] : [])].filter(Boolean).join('\n');
  else text = [law.id, ...documentary, ...law.trace, ...strategies, proposition(law.assertion),
    `Source: ${law.location.file}:${law.location.line}:${law.location.column}`,
    `Examples: ${law.examples.length}`].join('\n');
  if (view === 'evidence' && strategies.length) text += '\n' + strategies.join('\n');
  return { view, law: law.id, metadata, references, witnesses, searches, inputs: law.inputs, assertion: law.assertion, evidence, text };
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
