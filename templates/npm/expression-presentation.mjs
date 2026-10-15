// Render checked terms, without evaluating them or changing their evidence.
// Constructor(field = term) is presentation notation, not authoring syntax.
export function createExpressionPresentation(result, { constructors, typeName, storageView, isStoredValue = () => false }) {
  const unavailable = Symbol('unavailable expression presentation');
  const values = new Map();
  for (const unit of result.units ?? []) for (const declaration of unit.declarations) {
    const source = declaration.source;
    values.set(declaration.id, { name: source?.name ?? declaration.name,
      owner: source?.unit ?? (declaration.id.includes('::') ? declaration.id.slice(0, declaration.id.indexOf('::')) : unit.id),
      identity: source ? JSON.stringify([source.unit, source.name]) : declaration.id,
      canonicalName: source?.canonicalName });
  }
  for (const [id, entry] of constructors) if (entry.declaration.structure?.kind !== 'record')
    values.set(id, { name: entry.constructor.name, owner: entry.declaration.id.replace('::type::', '.') });
  const identities = new Map();
  for (const [id, value] of values) {
    if (!identities.has(value.name)) identities.set(value.name, new Set());
    identities.get(value.name).add(value.identity ?? id);
  }
  const counts = new Map([...identities].map(([name, owners]) => [name, owners.size]));
  const abilities = new Map((result.units ?? []).flatMap(unit => (unit.abilities ?? []).map(ability =>
    [ability.id, { name: ability.name, owner: ability.id.split('::')[0] }])));
  const abilityCounts = new Map();
  for (const { name } of abilities.values()) abilityCounts.set(name, (abilityCounts.get(name) ?? 0) + 1);
  const abilityIds = [...abilities.keys()].sort((a, b) => b.length - a.length);
  const spelling = name => name.startsWith('"|') || /^[\p{L}_][\p{L}\p{N}_]*$/u.test(name)
    ? name : `"|${name.replace(/[\\|]/g, '\\$&')}|`;
  const resultText = (text, atomic = false) => ({ text, atomic });
  const argument = value => value.atomic ? value.text : `(${value.text})`;

  function abilityName(key) {
    // The wire key appends parenthesized type arguments to the identity. Name
    // the known identity, retaining argument keys verbatim rather than guessing
    // types from text. Longest identity wins when phrase bodies contain '('.
    const id = abilityIds.find(id => key === id || key.startsWith(id + '('));
    if (id === undefined) return key;
    const ability = abilities.get(id), name = spelling(ability.name);
    return (abilityCounts.get(ability.name) > 1 ? `${ability.owner}.${name}` : name) + key.slice(id.length);
  }

  function globalName(id, scope) {
    const value = values.get(id);
    if (!value) throw unavailable;
    if (value.canonicalName) return value.canonicalName;
    const name = spelling(value.name);
    return counts.get(value.name) > 1 || [...scope.values()].includes(name)
      ? `${value.owner}.${name}` : name;
  }
  function children(expression, bound, onLocal) {
    const node = expression.node;
    if (!node) throw unavailable;
    const visit = (value, scope = bound) => children(value, scope, onLocal);
    const scoped = binders => new Set([...bound, ...binders.map(b => b.id)]);
    switch (node.kind) {
      case 'constant': return;
      case 'local': if (!bound.has(node.id)) onLocal(expression); return;
      case 'let': visit(node.value); visit(node.body, scoped([node.binder])); return;
      case 'match': visit(node.value); for (const branch of node.cases) visit(branch.body, scoped(branch.binders)); return;
      case 'allElements': visit(node.value); visit(node.predicate, scoped([node.binder])); return;
      case 'allPayloads': visit(node.value); for (const p of node.predicates) visit(p.predicate, scoped([p.binder])); return;
      case 'field': visit(node.value); return;
      case 'update': visit(node.value); visit(node.field); return;
      case 'binary':
      case 'shortCircuit': visit(node.left); visit(node.right); return;
      case 'unary':
      case 'convert': visit(node.argument); return;
      case 'if': visit(node.condition); visit(node.then); visit(node.else); return;
      case 'handle': visit(node.body); return;
      case 'construct':
      case 'call':
      case 'helper':
      case 'perform':
      case 'calls': for (const value of node.arguments ?? []) visit(value); return;
      default: throw unavailable;
    }
  }
  function freeLocals(expression) {
    const free = new Map();
    children(expression, new Set(), local => free.set(local.node.id, local.text));
    return free;
  }
  function bind(binder, scope, reserved) {
    // Source binders keep their spelling unless that would capture a name.
    // Generated temporaries have no authoring significance.
    const base = /^(?:~|_)?lawspec/.test(binder.name) ? 'value' : binder.name;
    const used = new Set([...scope.values(), ...reserved]);
    let name = base, suffix = 1;
    while (used.has(name)) name = `${base.startsWith('"|') ? 'value' : base}${suffix++}`;
    return { name, scope: new Map([...scope, [binder.id, name]]) };
  }
  function unwrap(expression) {
    let view;
    while ((view = storageView(expression)) !== undefined) expression = view;
    return expression;
  }
  // Flatten only the complete built-in list spine; unknown tails, conversions
  // and arbitrary computations remain explicit. Every head keeps source order.
  function listElements(expression) {
    const items = [];
    while (expression?.type?.kind === 'constructor' && expression.type.name === 'List') {
      const node = expression.node;
      if (node?.kind !== 'construct') return undefined;
      if (node.constructor === 'List::Nil' && node.arguments.length === 0) return items;
      if (node.constructor !== 'List::Cons' || node.arguments.length !== 2) return undefined;
      items.push(node.arguments[0]);
      expression = node.arguments[1];
    }
    return undefined;
  }
  function constructed(tag, entries, scope) {
    const entry = constructors.get(tag);
    if (!entry) throw unavailable;
    if (entry.declaration.structure?.kind === 'record')
      return resultText(`record{${entries.map(([label, value]) => `${label} = ${value.text}`).join(', ')}}`, true);
    const name = globalName(tag, scope);
    return resultText(entries.length ? `${name}(${entries.map(([label, value]) => `${label} = ${value.text}`).join(', ')})` : name, true);
  }
  function projection(expression) {
    const node = expression.node;
    if (node.kind !== 'match' || node.cases.length !== 1) return undefined;
    const branch = node.cases[0], entry = constructors.get(branch.constructor);
    if (!entry || entry.declaration.constructors.length !== 1
      || branch.binders.length !== entry.constructor.fields.length || branch.body.node?.kind !== 'local') return undefined;
    const index = branch.binders.findIndex(binder => binder.id === branch.body.node.id);
    return index < 0 ? undefined : { value: node.value, label: entry.constructor.fields[index].name };
  }
  function iterationCollection(expression) {
    const node = expression?.node;
    if (node?.kind === 'helper' && node.name === 'prelude.octets' && node.arguments.length === 1
      && node.arguments[0].type?.name === 'Bytes') return node.arguments[0];
    if (node?.kind !== 'match' || node.cases.length !== 1) return expression;
    const branch = node.cases[0], entry = constructors.get(branch.constructor);
    const types = ['EqSet', 'Set', 'Queue', 'Stack', 'Deque', 'KeyVal'].map(name => `lawspec.collections::type::${name}`);
    if (!entry || !types.includes(entry.declaration.id) || node.value.type?.name !== entry.declaration.id
      || entry.constructor.fields.length !== 1 || branch.binders.length !== 1
      || branch.body.node?.kind !== 'local' || branch.body.node.id !== branch.binders[0].id) return expression;
    return node.value;
  }
  function membership(expression, scope, reserved) {
    const outer = expression.node, inner = outer?.body?.node;
    if (outer?.kind !== 'let' || inner?.kind !== 'let' || outer.binder.id === inner.binder.id
      || freeLocals(inner.value).has(outer.binder.id)) return undefined;
    const negated = inner.body.node, iteration = negated?.argument?.node;
    if (negated?.kind !== 'unary' || negated.operator !== '!' || iteration?.kind !== 'allElements') return undefined;
    const collection = iterationCollection(iteration.value), comparison = iteration.predicate.node;
    if (collection.node?.kind !== 'local' || collection.node.id !== inner.binder.id
      || comparison?.kind !== 'binary' || comparison.operator !== '!='
      || comparison.left.node?.kind !== 'local' || comparison.left.node.id !== outer.binder.id
      || comparison.right.node?.kind !== 'local' || comparison.right.node.id !== iteration.binder.id) return undefined;
    // The exact typed shape consumes each strict argument once. Do not inline
    // dependent bindings, conversions, unknown tails or other computations.
    return resultText(`(${argument(render(outer.value, scope, reserved))} in ${argument(render(inner.value, scope, reserved))})`, true);
  }
  function literal(expression, scope, reserved) {
    const bindings = [];
    let body = expression;
    while (body.node?.kind === 'let') {
      bindings.push(body.node);
      body = body.node.body;
    }
    body = unwrap(body);
    const node = body.node, entry = constructors.get(node?.constructor);
    if (node?.kind !== 'construct' || !entry || node.arguments.length !== bindings.length
      || node.arguments.length !== entry.constructor.fields.length) return undefined;
    const positions = new Map();
    for (let i = 0; i < node.arguments.length; i++) {
      const value = unwrap(node.arguments[i]);
      if (value.node?.kind !== 'local' || positions.has(value.node.id)) return undefined;
      positions.set(value.node.id, i);
    }
    if (new Set(bindings.map(binding => binding.binder.id)).size !== bindings.length) return undefined;
    const preceding = new Set(), entries = [];
    for (const binding of bindings) {
      if (!positions.has(binding.binder.id) || [...freeLocals(binding.value).keys()].some(id => preceding.has(id))) return undefined;
      const index = positions.get(binding.binder.id);
      entries.push([entry.constructor.fields[index].name, render(binding.value, scope, reserved)]);
      preceding.add(binding.binder.id);
    }
    // Each strict binding occurs exactly once, only as its constructor field.
    // Entries stay in binding/evaluation order, independently of field order.
    return constructed(node.constructor, entries, scope);
  }
  function render(expression, scope, reserved) {
    expression = unwrap(expression);
    const node = expression.node;
    if (!node) throw unavailable;
    const go = (value, bindings = scope) => render(value, bindings, reserved);
    const args = values => values.map(value => argument(go(value))).join(' ');
    const list = listElements(expression);
    if (list !== undefined) return resultText(`[${list.map(value => go(value).text).join(', ')}]`, true);
    const select = projection(expression);
    if (select) return resultText(`${argument(go(select.value))}.${select.label}`, true);
    switch (node.kind) {
      case 'constant': return node.value?.type === 'Unit' ? resultText('()', true)
        : resultText(expression.text, /^(?:[+-]?\d+(?:\.\d+)?(?:[eE][+-]?\d+)?|true|false)$/.test(expression.text) || expression.text.startsWith('"'));
      case 'local': return resultText(scope.get(node.id) ?? expression.text, true);
      case 'construct': {
        if (node.constructor === 'lawspec.collections::type::EqSet::EqSetItems' && isStoredValue(expression)
          && node.arguments.length === 1) {
          const items = listElements(node.arguments[0]);
          if (items !== undefined) return resultText(`#S{${items.map(value => go(value).text).join(', ')}}`, true);
        }
        const entry = constructors.get(node.constructor);
        if (!entry || entry.constructor.fields.length !== node.arguments.length) throw unavailable;
        return constructed(node.constructor, node.arguments.map((value, i) => [entry.constructor.fields[i].name, go(value)]), scope);
      }
      case 'let': {
        const member = membership(expression, scope, reserved);
        if (member) return member;
        const record = literal(expression, scope, reserved);
        if (record) return record;
        const bound = bind(node.binder, scope, reserved);
        return resultText(`let ${bound.name} = ${go(node.value).text} in ${go(node.body, bound.scope).text}`);
      }
      case 'field': {
        const field = constructors.get(node.constructor)?.constructor.fields[node.index];
        if (!field) throw unavailable;
        return resultText(`${argument(go(node.value))}.${field.name}`, true);
      }
      case 'update': {
        const field = constructors.get(node.constructor)?.constructor.fields[node.index];
        if (!field) throw unavailable;
        return resultText(`${argument(go(node.value))} with ${field.name} = ${go(node.field).text}`);
      }
      case 'call': {
        // A checked public set constructor and a literal list have exactly the
        // authoring meaning of #S, including duplicate handling and order.
        if (values.get(node.declaration)?.canonicalName === 'prelude.setOf' && node.arguments.length === 1) {
          const items = listElements(node.arguments[0]);
          if (items !== undefined) return resultText(`#S{${items.map(value => go(value).text).join(', ')}}`, true);
        }
        return resultText(globalName(node.declaration, scope) + (node.arguments.length ? ` ${args(node.arguments)}` : ''));
      }
      case 'helper': return resultText(node.name + (node.arguments.length ? ` ${args(node.arguments)}` : ''));
      case 'binary':
      case 'shortCircuit': return resultText(`(${argument(go(node.left))} ${{ '==': '=', '&&': 'and', '||': 'or' }[node.operator] ?? node.operator} ${argument(go(node.right))})`, true);
      case 'unary': {
        const iteration = node.argument.node, predicate = iteration?.predicate?.node;
        if (node.operator === '!' && iteration?.kind === 'allElements' && predicate?.kind === 'unary' && predicate.operator === '!') {
          const bound = bind(iteration.binder, scope, reserved);
          return resultText(`any ${bound.name} in (${go(iterationCollection(iteration.value)).text}) satisfies (${go(predicate.argument, bound.scope).text})`);
        }
        return resultText(`${node.operator === '!' ? 'not' : node.operator} (${go(node.argument).text})`);
      }
      case 'if': return resultText(`if ${go(node.condition).text} then ${go(node.then).text} else ${go(node.else).text} end if`);
      case 'convert': return resultText(`${node.conversion} conversion of (${go(node.argument).text}) to ${typeName(expression.type)}`);
      case 'match': return resultText(`case ${argument(go(node.value))} of {${node.cases.map(branch => {
        let bindings = scope;
        const names = branch.binders.map(binder => {
          const bound = bind(binder, bindings, reserved);
          bindings = bound.scope;
          return bound.name;
        });
        const entry = constructors.get(branch.constructor);
        if (!entry || entry.constructor.fields.length !== names.length) throw unavailable;
        const pattern = entry.declaration.structure?.kind === 'record'
          ? `record{${names.map((name, i) => `${entry.constructor.fields[i].name} = ${name}`).join(', ')}}`
          : globalName(branch.constructor, scope) + (names.length ? `(${names.join(', ')})` : '');
        return `${pattern}: ${go(branch.body, bindings).text}`;
      }).join('; ')}}`);
      case 'allElements': {
        const bound = bind(node.binder, scope, reserved);
        return resultText(`every ${bound.name} in (${go(node.value).text}) satisfies (${go(node.predicate, bound.scope).text})`);
      }
      case 'allPayloads': return resultText(`allPayloads (${go(node.value).text}) [${node.predicates.map(predicate => {
        const bound = bind(predicate.binder, scope, reserved);
        return `${bound.name} of type ${typeName(predicate.binder.type)} => ${go(predicate.predicate, bound.scope).text}`;
      }).join('; ')}]`);
      case 'perform': return resultText(`perform ${abilityName(node.ability)}.${node.operation}(${node.arguments.map(value => go(value).text).join(', ')})`);
      case 'handle': {
        if (node.handling === 'catchFailure') return resultText(`catch failure of ${abilityName(node.ability)} in (${go(node.body).text})`);
        if (node.handling === 'withHandler') return resultText(`handle (${go(node.body).text}) with ${node.handler} for ${abilityName(node.ability)}`);
        throw unavailable;
      }
      case 'calls': return resultText(`calls of ${abilityName(node.ability)}.${node.operation}${node.arguments === null ? '' : ` with (${node.arguments.map(value => go(value).text).join(', ')})`}`);
      default: throw unavailable;
    }
  }
  return function expressionText(expression, scope = new Map()) {
    try {
      const free = freeLocals(expression);
      const reserved = new Set([...free].filter(([id]) => !scope.has(id)).map(([, name]) => name));
      return render(expression, new Map([...free, ...scope]), reserved).text;
    } catch (error) {
      // Fall back for the entire expression, including its original binders.
      // Mixing renamed binders with opaque child text could capture a local.
      if (error === unavailable) return expression.text;
      throw error;
    }
  };
}
