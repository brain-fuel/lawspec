/**
 * Native fast-check generation and shrinking for instantiated Core schemas.
 *
 * Generated tests run in fast-check, the framework JavaScript developers
 * already use, so failures shrink, replay and report as they expect; LawSpec
 * supplies only the arbitraries for its own types.
 * ref:DEC-native-property-frameworks ref:fast-check
 */
import * as fc from 'fast-check';
import * as ls from './lawspec_runtime.mjs';
import {RefinementViolation, witnessed, witnessInstances} from './lawspec_schema.mjs';

// fast-check has no empty arbitrary: an always-false filter would loop forever.
// A native factory may ignore this argument, but drawing it must fail promptly.
class EmptyArgumentArbitrary extends fc.Arbitrary {
  constructor(type, budget) {
    super();
    this.type = type;
    this.budget = budget;
  }

  generate() {
    throw new RangeError(
        `no native generator argument for ${JSON.stringify(this.type)} ` +
          `within node budget ${this.budget}`,
    );
  }

  canShrinkWithoutContext() {
    return false;
  }

  shrink() {
    return fc.Stream.nil();
  }
}

// Preserve the underlying Value and shrink context while bounding rejection.
class ContractArbitrary extends fc.Arbitrary {
  constructor(source, accepts, attempts, name) {
    super();
    this.source = source;
    this.accepts = accepts;
    this.attempts = attempts;
    this.name = name;
  }

  generate(random, bias) {
    for (let attempt = 0; attempt < this.attempts; ++attempt) {
      const value = this.source.generate(random, bias);
      if (this.accepts(value.value)) return value;
    }
    throw new RangeError(
        `constructor generation exhausted for ${this.name}`,
    );
  }

  canShrinkWithoutContext(value) {
    return (
      this.source.canShrinkWithoutContext(value) && this.accepts(value)
    );
  }

  shrink(value, context) {
    return this.source
        .shrink(value, context)
        .filter((candidate) => this.accepts(candidate.value));
  }
}

/**
 * Arbitraries are built from fast-check's own combinators so that its shrinker,
 * not a second one, reduces counterexamples, and shrinking stays within the
 * declared domain. ref:DEC-shrink-within-domain
 */
export function strategy(
    schema,
    reference,
    bits,
    budget,
    scalar,
    symbols = new Map(),
    witnesses = [],
    maxAttempts = 1000,
    nativeGenerators = new Map(),
    nativeSchema = schema,
    index = null,
) {
  if (!Number.isSafeInteger(budget) || budget < 1) {
    throw new RangeError('structural node budget must be positive');
  }
  if (bits !== 32 && bits !== 64) {
    throw new RangeError('machineBits must be 32 or 64');
  }
  schema.constructors(reference);
  nativeGenerators = new Map(nativeGenerators);
  for (const [name, factory] of nativeGenerators) {
    if (typeof name !== 'string' || typeof factory !== 'function') {
      throw new TypeError('invalid native generator binding');
    }
  }
  if (!Number.isSafeInteger(maxAttempts) || maxAttempts < 1) {
    throw new RangeError('constructor attempt budget must be positive');
  }
  const seeds = new Map();
  function remember(type, value) {
    const constructors = schema.constructors(type);
    let children = [];
    if (constructors !== null) {
      const constructor = constructors.find(
          (item) => item.tag === value.tag,
      );
      const types = witnessed(constructor, value.fields);
      children = constructor.fields.map((field, index) => [
        types[index],
        value.fields[index],
      ]);
    } else if (type.name === 'List') {
      children = value.map((child) => [type.args[0], child]);
    } else if (
        ['Nullable', 'Optional'].includes(type.name) &&
        value.present
    ) {
      children = [[type.args[0], value.value]];
    } else if (type.name === 'Maybe' && value.tag === 'Maybe::Just') {
      children = [[type.args[0], value.fields[0]]];
    } else if (type.name === 'Either') {
      children = [
        [type.args[value.tag === 'Either::Right' ? 1 : 0], value.fields[0]],
      ];
    }
    const cost =
        1 +
        children.reduce(
            (total, [childType, child]) => total + remember(childType, child),
            0,
        );
    const key = JSON.stringify(type);
    if (!seeds.has(key)) seeds.set(key, []);
    seeds.get(key).push({cost, value});
    return cost;
  }
  for (const value of witnesses) {
    remember(reference, schema.validate(reference, value, bits, symbols));
  }
  function accepts(type, value) {
    try {
      schema.validate(type, value, bits, symbols);
      return true;
    } catch (error) {
      if (error instanceof RefinementViolation) return false;
      throw error;
    }
  }
  const minima = new Map();
  const inhabitants = new Map();
  const arbitraries = new Map();
  const key = (type, available) => JSON.stringify([type, available]);

  function minimum(type, limit) {
    const id = key(type, limit);
    if (minima.has(id)) return minima.get(id);
    let result = null;
    for (let cost = 1; cost <= limit; ++cost) {
      if (inhabited(type, cost)) {
        result = cost;
        break;
      }
    }
    minima.set(id, result);
    return result;
  }

  function allocation(fields, available) {
    const costs = [];
    for (const field of fields) {
      const cost = minimum(field.type, available);
      if (cost === null) return null;
      costs.push(cost);
      available -= cost;
    }
    return costs.map(
        (cost, index) =>
            cost +
            Math.floor(available / costs.length) +
            Number(index < available % costs.length),
    );
  }

  function inhabited(type, available) {
    if (available < 1) return false;
    if (nativeGenerators.has(type.name)) return true;
    const id = key(type, available);
    if (inhabitants.has(id)) return inhabitants.get(id);
    const constructors = schema.constructors(type);
    let result;
    if (constructors !== null) {
      result = constructors.some((item) => witnessInstances(item).some(
          ([fields]) => allocation(fields, available - 1) !== null,
      ));
    } else if (
        type.args.length === 0 ||
        ['List', 'Maybe', 'Nullable', 'Optional'].includes(type.name)
    ) {
      result = true;
    } else if (type.name === 'Either') {
      result = type.args.some((child) => inhabited(child, available - 1));
    } else {
      throw new TypeError(`unsupported generator type: ${type.name}`);
    }
    inhabitants.set(id, result);
    return result;
  }

  function build(type, available) {
    const id = key(type, available);
    if (arbitraries.has(id)) return arbitraries.get(id);
    if (nativeGenerators.has(type.name)) {
      const children = type.args.map((child) => {
        const remaining = Math.max(1, available - 1);
        const source = inhabited(child, remaining)
          ? build(child, remaining)
          : new EmptyArgumentArbitrary(child, remaining);
        return source.map((value) =>
            nativeSchema.toNative(child, value, bits, symbols),
        );
      });
      const source = nativeGenerators.get(type.name)(...children);
      if (!(source instanceof fc.Arbitrary)) {
        throw new TypeError(
            `native generator ${type.name} must return an arbitrary`,
        );
      }
      const result = source.map((value) => {
        try {
          return nativeSchema.fromNative(type, value, bits, symbols);
        } catch (error) {
          throw new TypeError(
              `native generator ${type.name}: ${error.message}`,
              {cause: error},
          );
        }
      });
      arbitraries.set(id, result);
      return result;
    }
    if (!inhabited(type, available)) {
      throw new RangeError(
          `no value of ${type.name} within structural node budget ${available}`,
      );
    }
    const constructors = schema.constructors(type);
    let result;
    if (constructors !== null) {
      const alternatives = [];
      for (const constructor of constructors) {
        for (const [declared, keys] of witnessInstances(constructor)) {
          const costs = allocation(declared, available - 1);
          if (costs === null) continue;
          const children = declared.map((field, index) =>
              build(field.type, costs[index]),
          );
          const values = fc
              .tuple(...children)
              .map((fields) => new ls.DataValue(constructor.tag, [...fields, ...keys]));
          alternatives.push(values);
        }
      }
      result = fc.oneof({withCrossShrink: true}, ...alternatives);
      if (CANONICAL[type.name]) result = result.map(CANONICAL[type.name]);
    } else if (type.args.length === 0) {
      result = scalar(type.name).map((value) =>
          schema.validate(type, value, bits, symbols),
      );
    } else if (type.name === 'List') {
      const remaining = available - 1;
      const cost = minimum(type.args[0], remaining);
      const max = cost === null ? 0 : Math.floor(remaining / cost);
      result = fc.integer({min: 0, max}).chain((length) =>
          length === 0
            ? fc.constant([])
            : fc.array(build(type.args[0], Math.floor(remaining / length)), {
                minLength: length,
                maxLength: length,
              }),
      );
    } else if (['Maybe', 'Nullable', 'Optional'].includes(type.name)) {
      const maybe = type.name === 'Maybe';
      const absent = fc.constant(
          maybe
            ? new ls.DataValue('Maybe::Nothing', [])
            : new ls.Presence(type.name, false),
      );
      result = inhabited(type.args[0], available - 1)
        ? fc.oneof(
            {withCrossShrink: true},
            absent,
            build(type.args[0], available - 1).map((value) =>
                maybe
                  ? new ls.DataValue('Maybe::Just', [value])
                  : new ls.Presence(type.name, true, value),
            ),
          )
        : absent;
    } else if (type.name === 'Either') {
      const tags = ['Either::Left', 'Either::Right'];
      result = fc.oneof(
          {withCrossShrink: true},
          ...type.args.flatMap((child, index) =>
              inhabited(child, available - 1)
                ? [
                    build(child, available - 1).map(
                        (value) => new ls.DataValue(tags[index], [value]),
                    ),
                  ]
                : [],
          ),
      );
    } else {
      throw new TypeError(`unsupported generator type: ${type.name}`);
    }
    const values = (seeds.get(JSON.stringify(type)) ?? [])
        .filter((item) => item.cost <= available)
        .map((item) => item.value);
    if (values.length) {
      result = fc.oneof(
          {withCrossShrink: true},
          result,
          fc.constantFrom(...values),
      );
    }
    arbitraries.set(id, result);
    return result;
  }

  // Reject complete candidates, not subtrees: an impossible child must not
  // prevent choosing a viable sibling constructor on the next attempt.
  const root =
      index === null
        ? build(reference, budget)
        : indexedArbitrary(
            schema,
            reference,
            Number(index[0]),
            index[1],
            budget,
            build,
            inhabited,
            (type, value) => accepts(type, value),
          );
  return new ContractArbitrary(
      root,
      (value) => accepts(reference, value),
      maxAttempts,
      reference.name,
  );
}

// Sorted items without repeated keys: a Set's or a KeyVal's invariant.
function canonical(key) {
  return (value) => {
    const items = [...value.fields[0]].sort((a, b) => ls.compareValues(key(a), key(b)));
    const distinct = items.filter((item, index) =>
      index === 0 || ls.compareValues(key(items[index - 1]), key(item)) !== 0);
    return new ls.DataValue(value.tag, [distinct]);
  };
}

// Generated collections are canonicalised rather than filtered.
const CANONICAL = {
  'lawspec.collections::type::Set': canonical((item) => item),
  'lawspec.collections::type::KeyVal': canonical((entry) => entry.fields[0]),
};

const INDEX_SLACK = 16;
const INDEX_CHOICES = 6;
const INDEX_OPERATORS = ['+', '-', '*', 'div', 'mod', '^'];

// A prefix index term over field indices (f<i>), literals (c<n>) and the
// natural operators. Returns the term and the position after it.
function parseIndexTerm(tokens, at) {
  const token = tokens[at];
  if (token === undefined) throw new TypeError('malformed index term');
  if (token[0] === 'c') return [['c', Number(token.slice(1))], at + 1];
  if (token[0] === 'f') return [['f', Number(token.slice(1))], at + 1];
  if (INDEX_OPERATORS.includes(token)) {
    const [left, afterLeft] = parseIndexTerm(tokens, at + 1);
    const [right, afterRight] = parseIndexTerm(tokens, afterLeft);
    return [[token, left, right], afterRight];
  }
  throw new TypeError('malformed index term');
}

// Natural index arithmetic; null when an operation has no natural value.
function evalIndexTerm(term, fields) {
  if (term[0] === 'c') return term[1];
  if (term[0] === 'f') return fields.has(term[1]) ? fields.get(term[1]) : null;
  const x = evalIndexTerm(term[1], fields);
  const y = evalIndexTerm(term[2], fields);
  if (x === null || y === null) return null;
  let result;
  switch (term[0]) {
    case '+': result = x + y; break;
    case '-': result = x >= y ? x - y : null; break;
    case '*': result = x * y; break;
    case 'div': result = y > 0 ? Math.floor(x / y) : null; break;
    case 'mod': result = y > 0 ? x % y : null; break;
    default: result = y <= 64 ? x ** y : null;
  }
  return result !== null && Number.isSafeInteger(result) ? result : null;
}

function indexTermFields(term) {
  if (term[0] === 'c') return [];
  if (term[0] === 'f') return [term[1]];
  return [...indexTermFields(term[1]), ...indexTermFields(term[2])];
}

// Construct values whose structural index equals target. Each constructor
// carries its index term then its guards, in prefix notation over field
// indices. Reachability is a forward fixpoint over levels 0..target+slack, so
// a child may exceed its parent's index; the target is then solved backwards,
// and nothing is filtered away.
function indexedArbitrary(
    schema,
    reference,
    target,
    equations,
    budget,
    build,
    inhabited,
    accepts,
) {
  if (!Number.isSafeInteger(target)) {
    throw new RangeError('index target must be an integer');
  }
  if (schema.constructors(reference) === null) {
    throw new TypeError('indexed generation requires a data type');
  }
  const limit = Math.max(target, 0) + INDEX_SLACK;
  const key = (...parts) => JSON.stringify(parts);
  const parsed = new Map();
  const equation = (constructor) => {
    if (parsed.has(constructor.tag)) return parsed.get(constructor.tag);
    const texts = equations[constructor.tag];
    if (texts === undefined) {
      throw new TypeError(`missing index equation for ${constructor.tag}`);
    }
    const tokens = texts[0].split(' ');
    const [term, end] = parseIndexTerm(tokens, 0);
    if (end !== tokens.length) throw new TypeError('malformed index term');
    const guards = texts.slice(1).map((text) => {
      const parts = text.split(' ');
      if (parts[0] !== '==' && parts[0] !== '>=') {
        throw new TypeError('malformed index guard');
      }
      const [left, afterLeft] = parseIndexTerm(parts, 1);
      const [right] = parseIndexTerm(parts, afterLeft);
      return [parts[0], left, right];
    });
    const positions = [...new Set([
      ...indexTermFields(term),
      ...guards.flatMap(([, left, right]) => [
        ...indexTermFields(left), ...indexTermFields(right)]),
    ])];
    const result = {term, guards, positions};
    parsed.set(constructor.tag, result);
    return result;
  };
  const plainFields = (constructor, positions) =>
      constructor.fields.every(
          (field, index) =>
              positions.includes(index) || inhabited(field.type, budget),
      );
  const families = [];
  const familyKeys = new Set();
  const pending = [reference];
  while (pending.length) {
    const type = pending.pop();
    if (familyKeys.has(key(type))) continue;
    if (schema.constructors(type) === null) {
      throw new TypeError('indexed generation requires a data type');
    }
    familyKeys.add(key(type));
    families.push(type);
    for (const constructor of schema.constructors(type)) {
      for (const position of equation(constructor).positions) {
        pending.push(constructor.fields[position].type);
      }
    }
  }
  const holds = ([relation, left, right], fields) => {
    const x = evalIndexTerm(left, fields);
    const y = evalIndexTerm(right, fields);
    if (x === null || y === null) return false;
    return relation === '==' ? x === y : x >= y;
  };
  // Every assignment of reachable indices to the index fields that satisfies
  // the guards, with the index it produces.
  function assignments(constructor, reach) {
    const {term, guards, positions} = equation(constructor);
    const choices = positions.map((position) => {
      const values = [];
      for (let value = 0; value <= limit; ++value) {
        if (reach.has(key(constructor.fields[position].type, value))) {
          values.push([position, value]);
        }
      }
      return values;
    });
    const found = [];
    const extend = (at, current) => {
      if (at === choices.length) {
        const fields = new Map(current);
        if (guards.every((guard) => holds(guard, fields))) {
          const value = evalIndexTerm(term, fields);
          if (value !== null && value <= limit) found.push([value, current]);
        }
        return;
      }
      for (const choice of choices[at]) extend(at + 1, [...current, choice]);
    };
    extend(0, []);
    return found;
  }
  let reach = new Set();
  for (;;) {
    const grown = new Set(reach);
    for (const type of families) {
      for (const constructor of schema.constructors(type)) {
        if (!plainFields(constructor, equation(constructor).positions)) {
          continue;
        }
        for (const [value] of assignments(constructor, reach)) {
          grown.add(key(type, value));
        }
      }
    }
    if (grown.size === reach.size) break;
    reach = grown;
  }
  const solutions = new Map();
  const solve = (constructor, k) => {
    const id = key(constructor.tag, k);
    if (!solutions.has(id)) {
      solutions.set(id, assignments(constructor, reach)
          .filter(([value]) => value === k)
          .map(([, assignment]) => assignment));
    }
    return solutions.get(id);
  };
  const arbitraries = new Map();
  function indexed(type, k) {
    const id = key(type, k);
    if (arbitraries.has(id)) return arbitraries.get(id);
    const alternatives = [];
    for (const constructor of schema.constructors(type)) {
      if (!plainFields(constructor, equation(constructor).positions)) continue;
      const choices = solve(constructor, k);
      if (!choices.length) continue;
      const assemble = (assignment) => {
        const targets = new Map(assignment);
        return fc
            .tuple(
            ...constructor.fields.map((field, index) =>
                targets.has(index)
                  ? indexed(field.type, targets.get(index))
                  : build(field.type, budget),
            ),
          )
            .map((fields) => new ls.DataValue(constructor.tag, fields));
      };
      let values = fc.constantFrom(...choices).chain(assemble);
      if (constructor.predicates && constructor.predicates.length) {
        values = values.filter((value) => accepts(type, value));
      }
      alternatives.push(values);
    }
    if (!alternatives.length) {
      throw new RangeError(`no value of ${type.name} has index ${k}`);
    }
    const result =
        alternatives.length === 1
          ? alternatives[0]
          : fc.oneof({withCrossShrink: true}, ...alternatives);
    arbitraries.set(id, result);
    return result;
  }
  if (!reach.has(key(reference, target))) {
    // An open target (negative), or one drawn from earlier inputs that breaks
    // their preconditions or names no value, generates from the smallest
    // reachable indices; an index claim rejects a mismatch.
    const levels = [];
    for (let level = 0; level <= limit && levels.length < INDEX_CHOICES; ++level) {
      if (reach.has(key(reference, level))) levels.push(level);
    }
    if (!levels.length) {
      throw new RangeError(`no value of ${reference.name} has an index`);
    }
    return fc.constantFrom(...levels).chain((level) => indexed(reference, level));
  }
  return indexed(reference, target);
}
