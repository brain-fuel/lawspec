// Native fast-check generation and shrinking for instantiated Core schemas.
import * as fc from 'fast-check';
import * as ls from './lawspec_runtime.mjs';
import {RefinementViolation} from './lawspec_schema.mjs';

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
    throw new RangeError(`constructor generation exhausted for ${this.name}`);
  }

  canShrinkWithoutContext(value) {
    return this.source.canShrinkWithoutContext(value) && this.accepts(value);
  }

  shrink(value, context) {
    return this.source
        .shrink(value, context)
        .filter((candidate) => this.accepts(candidate.value));
  }
}

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
      const constructor = constructors.find((item) => item.tag === value.tag);
      children = constructor.fields.map((field, index) => [
        field.type,
        value.fields[index],
      ]);
    } else if (type.name === 'List') {
      children = value.map((child) => [type.args[0], child]);
    } else if (['Nullable', 'Optional'].includes(type.name) && value.present) {
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
      result = constructors.some(
          (item) => allocation(item.fields, available - 1) !== null,
      );
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
          nativeSchema.toNative(child, value, bits, symbols));
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
        const costs = allocation(constructor.fields, available - 1);
        if (costs === null) continue;
        const children = constructor.fields.map((field, index) =>
            build(field.type, costs[index]),
        );
        const values = fc
            .tuple(...children)
            .map((fields) => new ls.DataValue(constructor.tag, fields));
        alternatives.push(values);
      }
      result = fc.oneof({withCrossShrink: true}, ...alternatives);
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
  return new ContractArbitrary(
      build(reference, budget),
      (value) => accepts(reference, value),
      maxAttempts,
      reference.name,
  );
}
