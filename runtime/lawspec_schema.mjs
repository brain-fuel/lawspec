// Typed data validation and native bridges, independent of test frameworks.
import * as ls from './lawspec_runtime.mjs';

export class RefinementViolation extends TypeError {}

export class Parameter {
  constructor(index) {
    this.index = index;
    Object.freeze(this);
  }
}

export class Named {
  constructor(name, args = []) {
    this.name = name;
    this.args = Object.freeze([...args]);
    Object.freeze(this);
  }
}

export class Field {
  constructor(name, type) {
    this.name = name;
    this.type = type;
    Object.freeze(this);
  }
}

export class Constructor {
  constructor(
      tag,
      fields,
      native,
      predicates = [],
      nativeFields = null,
  ) {
    this.tag = tag;
    this.fields = Object.freeze([...fields]);
    this.native = native;
    this.predicates = Object.freeze([...predicates]);
    this.nativeFields =
        nativeFields === null
          ? null
          : Object.freeze([...nativeFields]);
    Object.freeze(this);
  }
}

export class Definition {
  constructor(name, parameters, constructors) {
    this.name = name;
    this.parameters = parameters;
    this.constructors = Object.freeze([...constructors]);
    Object.freeze(this);
  }
}

export function substitute(type, args) {
  return type instanceof Parameter
    ? args[type.index]
    : new Named(
        type.name,
        type.args.map((child) => substitute(child, args)),
      );
}

export function typeKey(type) {
  if (!(type instanceof Named)) {
    throw new TypeError(
        'type key requires an instantiated reference',
    );
  }
  const args = type.args.map(typeKey);
  if (!args.length) return type.name;
  if (type.name === 'Either' && args.length === 2) {
    return `Either (${args[0]}) (${args[1]})`;
  }
  if (args.length === 1) return `${type.name} ${args[0]}`;
  function pretty(value) {
    return (
      value.name +
        value.args.map((child) => ` (${pretty(child)})`).join('')
    );
  }
  return pretty(type);
}

export class Schema {
  #definitions = new Map();
  #arity;
  #builtins;
  #nativeCodecs = new Map();
  #canonical = null;

  constructor(definitions, primitives, builtins) {
    this.#arity = new Map(primitives.map((name) => [name, 0]));
    for (const [name, arity] of [
      ['List', 1],
      ['Maybe', 1],
      ['Either', 2],
      ['Nullable', 1],
      ['Optional', 1],
    ]) {
      this.#arity.set(name, arity);
    }
    for (const definition of definitions) {
      if (this.#arity.has(definition.name)) {
        throw new TypeError(`duplicate type: ${definition.name}`);
      }
      if (
          !Number.isSafeInteger(definition.parameters) ||
          definition.parameters < 0
      ) {
        throw new TypeError(
            `invalid parameter count: ${definition.name}`,
        );
      }
      this.#definitions.set(definition.name, definition);
      this.#arity.set(definition.name, definition.parameters);
    }
    const tags = new Set();
    const nativeClasses = new Set();
    this.#builtins = Object.freeze({...builtins});
    for (const name of [
      'nothing',
      'just',
      'left',
      'right',
      'presence',
    ]) {
      const native = this.#builtins[name];
      this.#checkNative(native, nativeClasses);
    }
    for (const definition of this.#definitions.values()) {
      for (const constructor of definition.constructors) {
        if (tags.has(constructor.tag)) {
          throw new TypeError(
              `duplicate constructor: ${constructor.tag}`,
          );
        }
        if (
            !constructor.predicates.every(
                (item) => typeof item === 'function',
            )
        ) {
          throw new TypeError(
              'constructor predicates must be callable',
          );
        }
        tags.add(constructor.tag);
        this.#checkNative(constructor.native, nativeClasses);
        if (constructor.nativeFields !== null) {
          const fields = constructor.nativeFields;
          if (
              fields.length !== constructor.fields.length ||
              new Set(fields).size !== fields.length ||
              !fields.every(
                  (field) =>
                      typeof field === 'string' &&
                      /^[A-Za-z_$][A-Za-z0-9_$]*$/.test(field),
              )
          ) {
            throw new TypeError('invalid native field mapping');
          }
        }
        const names = new Set();
        for (const field of constructor.fields) {
          if (names.has(field.name)) {
            throw new TypeError(
                `duplicate constructor field: ${field.name}`,
            );
          }
          names.add(field.name);
          this.#check(field.type, definition.parameters);
        }
      }
    }
  }

  #checkNative(native, names) {
    if (
        typeof native !== 'function' ||
        !native.prototype ||
        names.has(native)
    ) {
      throw new TypeError(
          'invalid or duplicate native constructor class',
      );
    }
    names.add(native);
  }

  #check(type, parameters = 0) {
    if (type instanceof Parameter) {
      if (
          !Number.isSafeInteger(type.index) ||
          type.index < 0 ||
          type.index >= parameters
      ) {
        throw new TypeError('unbound schema parameter');
      }
    } else if (type instanceof Named) {
      if (this.#arity.get(type.name) !== type.args.length) {
        throw new TypeError(
            `unknown type or wrong arity: ${type.name}`,
        );
      }
      for (const child of type.args) this.#check(child, parameters);
    } else {
      throw new TypeError('invalid schema type reference');
    }
  }

  constructors(type) {
    this.#check(type);
    const definition = this.#definitions.get(type.name);
    if (!definition) return null;
    return definition.constructors.map(
        (constructor) =>
            new Constructor(
                constructor.tag,
                constructor.fields.map(
                    (field) =>
                        new Field(
                            field.name,
                            substitute(field.type, type.args),
                        ),
                ),
                constructor.native,
                constructor.predicates,
                constructor.nativeFields,
            ),
    );
  }

  withNativeBindings(bindings, codecs = new Map()) {
    const remaining = new Map(bindings);
    const hooks = new Map([...this.#nativeCodecs, ...codecs]);
    for (const [name, hook] of hooks) {
      const definition = this.#definitions.get(name);
      if (!definition || !definition.constructors.length) {
        throw new TypeError(
            `unknown or empty native codec type: ${name}`,
        );
      }
      if (
          !hook ||
          typeof hook.native !== 'function' ||
          !hook.native.prototype ||
          typeof hook.toNative !== 'function' ||
          typeof hook.fromNative !== 'function'
      ) {
        throw new TypeError(`invalid native codec: ${name}`);
      }
      if (
          definition.constructors.some((item) =>
              remaining.has(item.tag),
          )
      ) {
        throw new TypeError(
            `codec conflicts with native mapping: ${name}`,
        );
      }
    }
    const definitions = [...this.#definitions.values()].map(
        (definition) =>
            new Definition(
                definition.name,
                definition.parameters,
                definition.constructors.map((constructor) => {
                  if (!remaining.has(constructor.tag)) return constructor;
                  const {native, fields} = remaining.get(constructor.tag);
                  remaining.delete(constructor.tag);
                  return new Constructor(
                      constructor.tag,
                      constructor.fields,
                      native,
                      constructor.predicates,
                      fields,
                  );
                }),
            ),
    );
    if (remaining.size) {
      throw new TypeError('unknown native constructor binding');
    }
    const structural = [
      'List',
      'Maybe',
      'Either',
      'Nullable',
      'Optional',
    ];
    const primitives = [...this.#arity.keys()].filter(
        (name) =>
            !this.#definitions.has(name) && !structural.includes(name),
    );
    const result = new Schema(
        definitions,
        primitives,
        this.#builtins,
    );
    result.#canonical = this.#canonical ?? this;
    result.#nativeCodecs = new Map(
        [...hooks].map(([name, hook]) => [
          name,
          Object.freeze({...hook}),
        ]),
    );
    return result;
  }

  #bits(bits) {
    if (bits !== 32 && bits !== 64) {
      throw new RangeError('machineBits must be 32 or 64');
    }
  }

  validate(type, value, bits = 64, symbols = new Map()) {
    this.#check(type);
    this.#bits(bits);
    return this.#walk(type, value, bits, 'validate', symbols);
  }

  allPayloads(
      type,
      value,
      predicates,
      bits = 64,
      symbols = new Map(),
  ) {
    this.#check(type);
    const structural = [
      'List',
      'Maybe',
      'Either',
      'Nullable',
      'Optional',
    ];
    if (
        !this.#definitions.has(type.name) &&
        !structural.includes(type.name)
    ) {
      throw new TypeError('payload predicates require a data type');
    }
    predicates = Array.from(predicates);
    if (predicates.length !== type.args.length) {
      throw new TypeError('payload predicate arity mismatch');
    }
    if (
        !predicates.every(
            (predicate) => typeof predicate === 'function',
        )
    ) {
      throw new TypeError('payload predicate must be callable');
    }
    const checked = this.validate(type, value, bits, symbols);
    const recipe = (field, args) => {
      if (field instanceof Parameter) return args[field.index];
      const children = field.args.map((child) =>
          recipe(child, args),
      );
      return children.some((child) => child !== null)
        ? new Named(field.name, children)
        : null;
    };
    const contextual = (plan, child, context) => {
      try {
        return walk(plan, child);
      } catch (error) {
        throw new TypeError(
            `${context}: ${error?.message ?? error}`,
            {cause: error},
        );
      }
    };
    const walk = (plan, child) => {
      if (plan === null) return true;
      if (plan instanceof Parameter) {
        const result = predicates[plan.index](child);
        if (typeof result !== 'boolean') {
          throw new TypeError(
              'payload predicate did not produce Bool',
          );
        }
        return result;
      }
      const {name, args} = plan;
      if (name === 'List') {
        return child.every((item, index) =>
            contextual(args[0], item, `List[${index}]`),
        );
      }
      if (name === 'Nullable' || name === 'Optional') {
        return (
          !child.present ||
            contextual(args[0], child.value, `${name}.value`)
        );
      }
      if (name === 'Maybe') {
        return (
          child.tag === 'Maybe::Nothing' ||
            contextual(args[0], child.fields[0], 'Maybe::Just.value')
        );
      }
      if (name === 'Either') {
        const index = child.tag === 'Either::Left' ? 0 : 1;
        return contextual(
            args[index],
            child.fields[0],
            `${child.tag}.value`,
        );
      }
      const constructor = this.#definitions
          .get(name)
          .constructors.find((item) => item.tag === child.tag);
      return constructor.fields.every((field, index) =>
          contextual(
              recipe(field.type, args),
              child.fields[index],
              `${constructor.tag}.${field.name}`,
          ),
      );
    };
    return walk(
        new Named(
            type.name,
            predicates.map((_, index) => new Parameter(index)),
        ),
        checked,
    );
  }

  toNative(type, value, bits = 64, symbols = new Map()) {
    return this.#walk(
        type,
        this.validate(type, value, bits, symbols),
        bits,
        'native',
        symbols,
    );
  }

  fromNative(type, value, bits = 64, symbols = new Map()) {
    this.#check(type);
    this.#bits(bits);
    return this.validate(
        type,
        this.#walk(type, value, bits, 'logical', symbols),
        bits,
        symbols,
    );
  }

  #codecWalk(type, value, bits, mode, symbols) {
    const hook = this.#nativeCodecs.get(type.name);
    const canonical = this.#canonical;
    const direction = mode === 'native' ? 'toNative' : 'fromNative';
    try {
      const children = type.args.map((argument) =>
          mode === 'native'
            ? (child) =>
                this.toNative(
                    argument,
                    canonical.fromNative(
                        argument,
                        child,
                        bits,
                        symbols,
                    ),
                    bits,
                    symbols,
                )
            : (child) =>
                canonical.toNative(
                    argument,
                    this.fromNative(argument, child, bits, symbols),
                    bits,
                    symbols,
                ),
      );
      if (mode === 'native') {
        const logical = canonical.toNative(
            type,
            value,
            bits,
            symbols,
        );
        const result = hook.toNative(logical, ...children);
        if (!(result instanceof hook.native)) {
          throw new TypeError(
              'hook returned the wrong native type',
          );
        }
        return result;
      }
      if (!(value instanceof hook.native)) {
        throw new TypeError('expected the bound native type');
      }
      const result = hook.fromNative(value, ...children);
      return canonical.fromNative(type, result, bits, symbols);
    } catch (error) {
      throw new TypeError(
          `native codec ${type.name} ${direction}: ${String(error)}`,
          {cause: error},
      );
    }
  }

  #walk(type, value, bits, mode, symbols) {
    if (mode !== 'validate' && this.#nativeCodecs.has(type.name)) {
      return this.#codecWalk(type, value, bits, mode, symbols);
    }
    const constructors = this.constructors(type);
    if (constructors !== null) {
      let constructor;
      let fields;
      if (mode === 'logical') {
        const prototype =
            value === null || value === undefined
              ? null
              : Object.getPrototypeOf(value);
        constructor = constructors.find(
            (item) => item.native.prototype === prototype,
        );
        if (!constructor) {
          throw new TypeError(`invalid native ${type.name}`);
        }
        fields = constructor.fields.map((field, index) => {
          const name =
              constructor.nativeFields?.[index] ?? field.name;
          if (!Object.hasOwn(value, name)) {
            throw new TypeError(
                `missing native field: ${field.name}`,
            );
          }
          return value[name];
        });
      } else {
        if (!(value instanceof ls.DataValue)) {
          throw new TypeError(`expected ${type.name}`);
        }
        constructor = constructors.find(
            (item) => value.tag === item.tag,
        );
        if (!constructor) {
          throw new TypeError(
              `foreign constructor for ${type.name}`,
          );
        }
        fields = value.fields;
      }
      if (fields.length !== constructor.fields.length) {
        throw new TypeError(
            `wrong field count: ${constructor.tag}`,
        );
      }
      const converted = constructor.fields.map((field, index) => {
        try {
          return this.#walk(
              field.type,
              fields[index],
              bits,
              mode,
              symbols,
          );
        } catch (error) {
          const ErrorClass =
              error instanceof RefinementViolation
                ? RefinementViolation
                : TypeError;
          throw new ErrorClass(
              `${constructor.tag}.${field.name}: ${error.message}`,
              {cause: error},
          );
        }
      });
      if (mode === 'validate') {
        constructor.predicates.forEach((predicate, index) => {
          const context = `${constructor.tag}: field refinement ${index + 1}`;
          let accepted;
          try {
            accepted = predicate(
                this,
                type.args,
                converted,
                bits,
                symbols,
            );
          } catch (error) {
            throw new TypeError(`${context}: ${error.message}`, {
              cause: error,
            });
          }
          if (accepted === false) {
            throw new RefinementViolation(`${context} failed`);
          }
          if (accepted !== true) {
            throw new TypeError(`${context} did not produce Bool`);
          }
        });
      }
      if (mode === 'native' && constructor.nativeFields !== null) {
        return converted.length === 0
          ? new constructor.native()
          : new constructor.native(
              Object.fromEntries(
                  constructor.nativeFields.map((name, index) => [
                    name,
                    converted[index],
                  ]),
              ),
            );
      }
      return mode === 'native'
        ? new constructor.native(...converted)
        : new ls.DataValue(constructor.tag, converted);
    }
    const {name, args} = type;
    if (args.length === 0) return ls.validate(value, name, bits);
    if (name === 'List') {
      if (!Array.isArray(value))
        throw new TypeError('expected List');
      return Array.from(value, (child, index) => {
        if (!Object.hasOwn(value, index)) {
          throw new TypeError(
              `List[${index}]: array holes are not values`,
          );
        }
        try {
          return this.#walk(args[0], child, bits, mode, symbols);
        } catch (error) {
          const ErrorClass =
              error instanceof RefinementViolation
                ? RefinementViolation
                : TypeError;
          throw new ErrorClass(`List[${index}]: ${error.message}`, {
            cause: error,
          });
        }
      });
    }
    if (name === 'Nullable' || name === 'Optional') {
      if (
          !(value instanceof ls.Presence) ||
          value.kind !== name ||
          typeof value.present !== 'boolean'
      ) {
        throw new TypeError(`invalid tagged presence: ${name}`);
      }
      const payload = value.present
        ? this.#walk(args[0], value.value, bits, mode, symbols)
        : undefined;
      const Native =
          mode === 'native' ? this.#builtins.presence : ls.Presence;
      return new Native(name, value.present, payload);
    }
    if (name === 'Maybe' || name === 'Either') {
      const classes =
          name === 'Maybe'
            ? [this.#builtins.nothing, this.#builtins.just]
            : [this.#builtins.left, this.#builtins.right];
      const tags =
          name === 'Maybe'
            ? ['Maybe::Nothing', 'Maybe::Just']
            : ['Either::Left', 'Either::Right'];
      let index;
      let fields;
      if (mode === 'logical') {
        const prototype =
            value === null || value === undefined
              ? null
              : Object.getPrototypeOf(value);
        index = classes.findIndex(
            (native) => native.prototype === prototype,
        );
        if (index === -1)
          throw new TypeError(`invalid native ${name}`);
        if (
            !(name === 'Maybe' && index === 0) &&
            !Object.hasOwn(value, 'value')
        ) {
          throw new TypeError(`missing native ${name} payload`);
        }
        fields =
            name === 'Maybe' && index === 0 ? [] : [value.value];
      } else {
        if (
            !(value instanceof ls.DataValue) ||
            !tags.includes(value.tag)
        ) {
          throw new TypeError(`invalid constructor for ${name}`);
        }
        index = tags.indexOf(value.tag);
        fields = value.fields;
      }
      const arity = name === 'Maybe' && index === 0 ? 0 : 1;
      if (fields.length !== arity) {
        throw new TypeError(`wrong constructor arity for ${name}`);
      }
      const converted =
          arity === 0
            ? []
            : [
                this.#walk(
                    args[name === 'Maybe' ? 0 : index],
                    fields[0],
                    bits,
                    mode,
                    symbols,
                ),
              ];
      return mode === 'native'
        ? new classes[index](...converted)
        : new ls.DataValue(tags[index], converted);
    }
    throw new TypeError(`unsupported type: ${name}`);
  }

  construct(type, tag, fields, bits = 64, symbols = new Map()) {
    const value =
        type.name === 'List'
          ? ls.construct(tag, fields)
          : new ls.DataValue(tag, fields);
    return this.validate(type, value, bits, symbols);
  }

  match(type, value, branches, bits = 64, symbols = new Map()) {
    const checked = this.validate(type, value, bits, symbols);
    if (type.name === 'List')
      return ls.matchList(checked, branches);
    for (const [tag, branch] of branches) {
      if (checked.tag === tag) return branch(...checked.fields);
    }
    throw new TypeError(`missing match branch: ${checked.tag}`);
  }

  equal(type, left, right, bits = 64, symbols = new Map()) {
    left = this.validate(type, left, bits, symbols);
    right = this.validate(type, right, bits, symbols);
    const constructors = this.constructors(type);
    if (constructors !== null) {
      if (left.tag !== right.tag) return false;
      const constructor = constructors.find(
          (item) => item.tag === left.tag,
      );
      return constructor.fields.every((field, index) =>
          this.equal(
              field.type,
              left.fields[index],
              right.fields[index],
              bits,
              symbols,
          ),
      );
    }
    const {name, args} = type;
    if (args.length === 0) return ls.equal(left, right, name, name);
    if (name === 'List') {
      return (
        left.length === right.length &&
          left.every((item, index) =>
              this.equal(args[0], item, right[index], bits, symbols),
          )
      );
    }
    if (name === 'Nullable' || name === 'Optional') {
      return (
        left.present === right.present &&
          (!left.present ||
            this.equal(
                args[0],
                left.value,
                right.value,
                bits,
                symbols,
            ))
      );
    }
    if (left.tag !== right.tag) return false;
    if (left.fields.length === 0) return true;
    const index = left.tag === 'Either::Right' ? 1 : 0;
    return this.equal(
        args[index],
        left.fields[0],
        right.fields[0],
        bits,
        symbols,
    );
  }
}
