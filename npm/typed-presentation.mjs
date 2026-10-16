// Generated from templates/npm/typed-presentation.mjs by lawspec-dev generate. Do not edit.
// Presentation only: identities, constraints and proof evidence remain in Core.
// In particular, a nominal record is never expanded into a structural product.
import { createExpressionPresentation } from './expression-presentation.mjs';
import { builtinDataNames } from './builtin-data-names.mjs';
import { showScalar } from './scalars.mjs';
import { positionalFields } from './positional-fields.mjs';

export function createTypePresentation(result) {
  const declarations = new Map([...builtinDataNames, ...(result.dataTypes ?? [])].map(d => [d.id, d]));
  const constructors = new Map([...declarations.values()].flatMap(d =>
    d.constructors.map(c => [c.id, { declaration: d, constructor: c }])));
  const shortName = name => ({ BigUInt: 'Whole', BigInt: 'Integer', Natural: 'Whole' })[name]
    ?? declarations.get(name)?.name ?? name.split('::type::').at(-1);
  const names = new Map();
  for (const d of declarations.values()) {
    const name = shortName(d.id);
    names.set(name, (names.get(name) ?? 0) + 1);
  }
  const nominalName = name => {
    const display = shortName(name), separator = name.indexOf('::type::');
    return names.get(display) > 1 && separator >= 0
      ? `${name.slice(0, separator)}.${display}` : display;
  };

  // The compiler marks ordinary checked recursive representation definitions.
  // Names alone do not authorize hiding a call, and its full signature must
  // agree with the typed application. The wire assertion is never rewritten.
  const recursiveViews = new Map((result.units ?? []).flatMap(unit => unit.declarations
    .filter(d => d.representation === 'structural-record-storage' && d.source === undefined
      && d.origin?.kind === 'generated' && d.origin.declaration === d.id && d.type.kind === 'function')
    .map(d => [d.id, d.type])));
  function sameType(left, right) {
    if (!left || !right || left.kind !== right.kind) return false;
    if (left.kind === 'variable') return left.id === right.id;
    if (left.kind === 'function') return sameType(left.parameter, right.parameter) && sameType(left.result, right.result);
    if (left.kind !== 'constructor' || left.name !== right.name || left.arguments.length !== right.arguments.length) return false;
    return left.arguments.every((a, i) => {
      const b = right.arguments[i];
      return a.kind === b.kind && (a.kind === 'type' ? sameType(a.type, b.type)
        : a.kind === 'natural' ? a.value === b.value : a.kind === 'indexVariable' && a.id === b.id);
    });
  }

  // Recognize only compiler-generated storage views which copy every field in
  // order. Do not simplify user matches, erase conversions or discard unused
  // constructor arguments: those may contain checks or undefined computations.
  function storageView(expression) {
    const node = expression.node;
    if (node?.kind === 'call') {
      const signature = recursiveViews.get(node.declaration);
      return signature && node.arguments.length === 1
        && sameType(signature.parameter, node.arguments[0].type) && sameType(signature.result, expression.type)
        ? node.arguments[0] : undefined;
    }
    if (node?.kind !== 'match' || node.cases.length !== 1) return undefined;
    const branch = node.cases[0], body = branch.body.node;
    const source = constructors.get(branch.constructor), target = constructors.get(body?.constructor);
    if (body?.kind !== 'construct' || !source || !target
      || source.declaration.structure?.kind !== 'record' || target.declaration.structure?.kind !== 'record'
      || expression.origin?.kind !== 'generated'
      || !branch.binders.length || !branch.binders.every(b => b.id.startsWith('lawspec::record-view::'))
      || branch.binders.length !== source.constructor.fields.length
      || body.arguments.length !== branch.binders.length
      || target.constructor.fields.length !== branch.binders.length) return undefined;
    for (let i = 0; i < branch.binders.length; i++) {
      if (source.constructor.fields[i].name !== target.constructor.fields[i].name) return undefined;
      let argument = body.arguments[i], unwrapped;
      while ((unwrapped = storageView(argument)) !== undefined) argument = unwrapped;
      if (argument.node?.kind !== 'local' || argument.node.id !== branch.binders[i].id) return undefined;
    }
    return node.value;
  }

  function expressionText(expression, locals) {
    const view = storageView(expression);
    if (view) return expressionText(view, locals);
    const node = expression.node;
    switch (node?.kind) {
      case 'local': return locals.get(node.id) ?? expression.text;
      case 'field': {
        const field = constructors.get(node.constructor)?.constructor.fields[node.index];
        if (!field) return expression.text;
        let value = node.value, unwrapped;
        while ((unwrapped = storageView(value)) !== undefined) value = unwrapped;
        const text = expressionText(value, locals);
        return `${['local', 'field'].includes(value.node?.kind) ? text : `(${text})`}.${field.name}`;
      }
      case 'binary':
      case 'shortCircuit': return `(${expressionText(node.left, locals)} ${{ '==': '=', '&&': 'and', '||': 'or' }[node.operator] ?? node.operator} ${expressionText(node.right, locals)})`;
      case 'unary': return `${node.operator === '!' ? 'not' : node.operator} (${expressionText(node.argument, locals)})`;
      // Keep unfamiliar expressions verbatim; never omit a restriction because
      // a presentation does not yet know its typed node.
      default: return expression.text;
    }
  }

  function typeName(type, substitutions = new Map(), active = new Set()) {
    if (type.kind === 'variable') {
      const replacement = substitutions.get(type.id);
      return replacement ? typeName(replacement) : type.id;
    }
    if (type.kind === 'function') return `(${typeName(type.parameter, substitutions, active)} -> ${typeName(type.result, substitutions, active)})`;
    if (type.kind !== 'constructor') return type.id;
    const declaration = declarations.get(type.name);
    const argumentsText = () => type.arguments.map(a => {
      if (a.kind !== 'type') return a.value ?? a.id;
      const text = typeName(a.type, substitutions, active);
      return a.type.kind === 'constructor' && a.type.arguments.length ? `(${text})` : text;
    }).join(' ');
    const named = () => nominalName(type.name) + (type.arguments.length ? ` ${argumentsText()}` : '');
    if (declaration?.structure?.kind !== 'record' || active.has(type.name)) return named();
    const constructor = declaration.constructors[0];
    const bindings = new Map(substitutions);
    declaration.parameters.forEach((parameter, i) => {
      const argument = type.arguments[i];
      if (argument?.kind === 'type') bindings.set(parameter, substitute(argument.type, substitutions));
    });
    const nested = new Set([...active, type.name]);
    const positions = positionalFields(declaration);
    const ordered = positions ?? constructor.fields;
    const locals = new Map(ordered.map((f, index) => [f.id, positions ? `component${index + 1}` : f.name]));
    const fields = ordered.map(field => {
      const base = typeName(field.type, bindings, nested);
      const predicates = declaration.structure.fields.find(f => f.name === field.name)?.predicates ?? [];
      const name = locals.get(field.id);
      const refined = predicates.length
        ? `(${name} of type ${base} where ${predicates.map(p => expressionText(p, locals)).join(' and ')})`
        : base;
      return positions ? refined : `${field.name} of type ${refined}`;
    });
    if (positions) return `(${fields.join(', ')})`;
    return `record{${fields.join(', ')}}`;
  }
  function substitute(type, bindings) {
    if (type.kind === 'variable') return bindings.get(type.id) ?? type;
    if (type.kind === 'function') return { ...type, parameter: substitute(type.parameter, bindings), result: substitute(type.result, bindings) };
    if (type.kind === 'constructor') return { ...type, arguments: type.arguments.map(a => a.kind === 'type'
      ? { ...a, type: substitute(a.type, bindings) } : a) };
    return type;
  }
  // Only concrete bindings have already passed the compiler's stored-value
  // validation. Keep that fact outside the wire expression objects.
  const storedValues = new WeakSet();
  const checkedExpressionText = createExpressionPresentation(result, { constructors, typeName, storageView,
    isStoredValue: expression => storedValues.has(expression) });
  // Example bindings are already checked concrete values. Render their stored
  // structure through the same constructor metadata; do not execute anything.
  function valueExpression(value) {
    const text = JSON.stringify(value);
    if (value?.kind === 'data') {
      const expression = {type: value.type, text,
        node: {kind: 'construct', constructor: value.constructor,
          arguments: value.fields.map(valueExpression)}};
      storedValues.add(expression);
      return expression;
    }
    return {type: {kind: 'constructor', name: value.type, arguments: []},
      text: showScalar(value), node: {kind: 'constant', value}};
  }
  function valueText(value, scope = new Map()) {
    return checkedExpressionText(valueExpression(value), scope);
  }
  return { typeName, expressionText: checkedExpressionText, valueText };
}
