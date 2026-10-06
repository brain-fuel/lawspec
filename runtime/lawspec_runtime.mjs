// LawSpec scalar runtime. No test framework dependencies.
export class Rational {
  constructor(n, d = 1n) {
    n = BigInt(n);
    d = BigInt(d);
    if (!d) throw new RangeError('exact division by zero');
    if (d < 0n) {
      n = -n;
      d = -d;
    }
    let a = n < 0n ? -n : n,
        b = d;
    while (b) [a, b] = [b, a % b];
    this.n = n / a;
    this.d = d / a;
    Object.freeze(this);
  }
  toString() {
    return `${this.n}/${this.d}`;
  }
}
export class Decimal {
  constructor(coefficient, exponent = 0n) {
    this.coefficient = BigInt(coefficient);
    this.exponent = BigInt(exponent);
    Object.freeze(this);
  }
  toString() {
    return `${this.coefficient}e${this.exponent}`;
  }
}
export class Complex {
  constructor(real, imaginary) {
    this.real = real;
    this.imaginary = imaginary;
    Object.freeze(this);
  }
}
export class Raw {
  constructor(kind, units) {
    this.kind = kind;
    this.units = Object.freeze([...units]);
    Object.freeze(this);
  }
}
export class Presence {
  constructor(kind, present, value) {
    this.kind = kind;
    this.present = present;
    this.value = value;
    Object.freeze(this);
  }
}

export class DataValue {
  constructor(tag, fields) {
    this.tag = tag;
    this.fields = Object.freeze([...fields]);
    Object.freeze(this);
  }
}
export const UNIT = Object.freeze({kind: 'Unit'});
export const integerType = (t) =>
    /^(U?Int(8|16|32|64|Size)|UIntPtr|BigU?Int|Integer)$/.test(t);
export const exactType = (t) =>
    integerType(t) || ['Decimal', 'Rational'].includes(t);
export function ratio(x) {
  if (x instanceof Rational) return x;
  if (x instanceof Decimal)
    return x.exponent >= 0n
      ? new Rational(x.coefficient * 10n ** x.exponent)
      : new Rational(x.coefficient, 10n ** -x.exponent);
  if (typeof x === 'bigint') return new Rational(x);
  if (typeof x === 'number' && Number.isInteger(x))
    return new Rational(BigInt(x));
  throw new TypeError('exact numeric value required');
}
export function bounds(t, bits = 64) {
  if (t === 'BigInt' || t === 'Integer') return [null, null];
  if (t === 'BigUInt') return [0n, null];
  const w = BigInt(
      ['IntSize', 'UIntSize', 'UIntPtr'].includes(t)
        ? bits
        : t.match(/\d+/)[0],
  );
  return t.startsWith('U')
    ? [0n, 2n ** w - 1n]
    : [-(2n ** (w - 1n)), 2n ** (w - 1n) - 1n];
}
function decimal(x) {
  const r = ratio(x);
  let d = r.d,
      a = 0n,
      b = 0n;
  while (d % 2n === 0n) {
    d /= 2n;
    a++;
  }
  while (d % 5n === 0n) {
    d /= 5n;
    b++;
  }
  if (d !== 1n)
    throw new RangeError('Decimal conversion is not finite; use round');
  const scale = a > b ? a : b;
  return new Decimal(r.n * 2n ** (scale - a) * 5n ** (scale - b), -scale);
}
export function convert(x, t, bits = 64) {
  if (integerType(t)) {
    const r =
        typeof x === 'number' && Number.isFinite(x)
          ? floatRatio(x)
          : ratio(x);
    if (r.d !== 1n) throw new RangeError('fractional conversion to ' + t);
    const [lo, hi] = bounds(t, bits);
    if ((lo !== null && r.n < lo) || (hi !== null && r.n > hi))
      throw new RangeError('integer outside ' + t + ' range');
    return ['Int8', 'Int16', 'Int32', 'UInt8', 'UInt16', 'UInt32'].includes(
        t,
    )
      ? Number(r.n)
      : r.n;
  }
  if (t === 'Rational')
    return typeof x === 'number' ? floatRatio(x) : ratio(x);
  if (t === 'Decimal')
    return decimal(typeof x === 'number' ? floatRatio(x) : x);
  if (t === 'Float32' || t === 'Float64') {
    let v;
    if (typeof x === 'number') v = x;
    else v = exactFloat(ratio(x), t);
    return t === 'Float32' ? Math.fround(v) : v;
  }
  if (t === 'Complex64' || t === 'Complex128') {
    const z =
        x instanceof Complex
          ? x
          : new Complex(
              convert(x, t === 'Complex64' ? 'Float32' : 'Float64'),
              0,
            );
    return t === 'Complex64'
      ? new Complex(Math.fround(z.real), Math.fround(z.imaginary))
      : z;
  }
  return validate(x, t, bits);
}
function floatRatio(x) {
  if (!Number.isFinite(x))
    throw new RangeError('non-finite exact conversion');
  if (x === 0) return new Rational(0n);
  const a = new DataView(new ArrayBuffer(8));
  a.setFloat64(0, x);
  const bits = a.getBigUint64(0),
      sign = bits >> 63n ? -1n : 1n;
  const exp = (bits >> 52n) & 2047n,
      mant = (bits & ((1n << 52n) - 1n)) + (exp ? 1n << 52n : 0n),
      shift = (exp || 1n) - 1075n;
  return shift >= 0
    ? new Rational(sign * mant * 2n ** shift)
    : new Rational(sign * mant, 2n ** -shift);
}
function validUnit(t, c) {
  return (
    Number.isInteger(c) &&
      c >= 0 &&
      c <=
        (t === 'Bytes'
          ? 255
          : ['Utf16Text', 'CodeUnit16'].includes(t)
            ? 65535
            : 1114111) &&
      (!['Text', 'Char'].includes(t) || c < 55296 || c > 57343)
  );
}
export function validate(x, t, bits = 64) {
  if (t.startsWith('Either ')) {
    const types = eitherArguments(t);
    if (
        !(x instanceof DataValue) ||
        x.fields.length !== 1 ||
        !['Either::Left', 'Either::Right'].includes(x.tag)
    ) {
      throw new TypeError('invalid Either constructor or arity');
    }
    const inner = types[x.tag === 'Either::Left' ? 0 : 1];
    return new DataValue(x.tag, [validate(x.fields[0], inner, bits)]);
  }
  if (t.startsWith('Maybe ')) {
    if (!(x instanceof DataValue)) throw new TypeError('expected Maybe');
    if (x.tag === 'Maybe::Nothing' && x.fields.length === 0) return x;
    if (x.tag === 'Maybe::Just' && x.fields.length === 1) {
      return new DataValue(x.tag, [
        validate(x.fields[0], t.slice(6), bits),
      ]);
    }
    throw new TypeError('invalid Maybe constructor or arity');
  }
  if (t.startsWith('List ')) {
    if (!Array.isArray(x)) throw new TypeError('expected List');
    return Array.from(x, (value, index) => {
      if (!Object.hasOwn(x, index))
        throw new TypeError('List cannot contain array holes');
      return validate(value, t.slice(5), bits);
    });
  }
  const fail = () => {
    throw new TypeError('invalid ' + t + ' value');
  };
  if (t.startsWith('Nullable ') || t.startsWith('Optional ')) {
    const i = t.indexOf(' '),
        kind = t.slice(0, i);
    if (
        !(x instanceof Presence) ||
        x.kind !== kind ||
        typeof x.present !== 'boolean'
    )
      fail();
    if (x.present)
      return new Presence(
          kind,
          true,
          validate(x.value, t.slice(i + 1), bits),
      );
  } else if (integerType(t)) {
    if (
        !['number', 'bigint'].includes(typeof x) ||
        (typeof x === 'number' && !Number.isSafeInteger(x))
    )
      fail();
    return convert(x, t, bits);
  } else if (t === 'Bool') {
    if (typeof x !== 'boolean') fail();
  } else if (t === 'Text' || t === 'Char') {
    if (
        typeof x !== 'string' ||
        (t === 'Char' && [...x].length !== 1) ||
        ![...x].every((c) => validUnit(t, c.codePointAt(0)))
    )
      fail();
  } else if (t === 'CodePoint' || t === 'CodeUnit16') {
    if (!validUnit(t, x)) fail();
  } else if (t === 'Bytes') {
    if (!(x instanceof Uint8Array)) fail();
    return new Uint8Array(x);
  } else if (['Utf16Text', 'CodePointText'].includes(t)) {
    if (
        !(x instanceof Raw) ||
        x.kind !== t ||
        !x.units.every((c) => validUnit(t, c))
    )
      fail();
  } else if (t === 'Symbol') {
    if (typeof x !== 'symbol') fail();
  } else if (t === 'Unit') {
    if (x !== UNIT) fail();
  } else if (t === 'Null') {
    if (x !== null) fail();
  } else if (t === 'Undefined') {
    if (x !== undefined) fail();
  } else if (t === 'Decimal') {
    if (!(x instanceof Decimal)) fail();
  } else if (t === 'Rational') {
    if (!(x instanceof Rational)) fail();
  } else if (t.startsWith('Float')) {
    if (
        typeof x !== 'number' ||
        (t === 'Float32' && !Number.isNaN(x) && Math.fround(x) !== x)
    )
      fail();
  } else if (t.startsWith('Complex')) {
    if (!(x instanceof Complex)) fail();
    validate(x.real, t === 'Complex64' ? 'Float32' : 'Float64');
    validate(x.imaginary, t === 'Complex64' ? 'Float32' : 'Float64');
  } else fail();
  return x;
}
export function literal(v, symbols = new Map()) {
  const t = v.type;
  if (integerType(t)) return convert(BigInt(v.value), t);
  if (t === 'Bool') return v.value;
  if (t === 'Decimal') return new Decimal(v.coefficient, v.exponent);
  if (t === 'Rational') return new Rational(v.numerator, v.denominator);
  if (t.startsWith('Float')) {
    const a = new DataView(new ArrayBuffer(8));
    if (t === 'Float32') {
      a.setUint32(0, Number.parseInt(v.bits, 16));
      return a.getFloat32(0);
    }
    a.setBigUint64(0, BigInt('0x' + v.bits));
    return a.getFloat64(0);
  }
  if (t.startsWith('Complex'))
    return new Complex(literal(v.real), literal(v.imaginary));
  if (t === 'Text')
    return v.units.map((c) => String.fromCodePoint(c)).join('');
  if (t === 'Char') return String.fromCodePoint(v.value);
  if (t === 'CodePoint' || t === 'CodeUnit16') return v.value;
  if (t === 'Bytes') {
    if (!v.units.every((c) => validUnit(t, c)))
      throw new RangeError('invalid Bytes');
    return new Uint8Array(v.units);
  }
  if (['CodePointText', 'Utf16Text'].includes(t))
    return new Raw(t, v.units);
  if (t === 'Symbol') {
    if (!symbols.has(v.id)) symbols.set(v.id, Symbol(v.description));
    return symbols.get(v.id);
  }
  if (t === 'Nullable' || t === 'Optional')
    return new Presence(
        t,
        v.value !== null,
        v.value === null ? undefined : literal(v.value, symbols),
    );
  if (t === 'Null') return null;
  if (t === 'Undefined') return undefined;
  return UNIT;
}
export function promote(a, b, op) {
  if (exactType(a) !== exactType(b))
    throw new TypeError(
        'exact/inexact mixing requires explicit conversion',
    );
  if (exactType(a))
    return op === '/' || [a, b].includes('Rational')
      ? 'Rational'
      : [a, b].includes('Decimal')
        ? 'Decimal'
        : 'Integer';
  if (a.startsWith('Complex') || b.startsWith('Complex'))
    return [a, b].some((t) => ['Float64', 'Complex128'].includes(t))
      ? 'Complex128'
      : 'Complex64';
  return [a, b].includes('Float64') ? 'Float64' : 'Float32';
}
export function binary(op, a, b, ta, tb) {
  if (
      (op === '==' || op === '!=') &&
      !exactType(ta) &&
      !['Float32', 'Float64', 'Complex64', 'Complex128'].includes(ta)
  ) {
    const result = equal(a, b, ta, tb);
    return op === '==' ? result : !result;
  }
  const t = promote(ta, tb, op);
  if (exactType(ta)) {
    a = ratio(a);
    b = ratio(b);
    const x = a.n * b.d,
        y = b.n * a.d;
    if (['==', '!=', '<', '<=', '>', '>='].includes(op))
      return compare(op, x, y);
    let r;
    if (op === '+') r = new Rational(x + y, a.d * b.d);
    else if (op === '-') r = new Rational(x - y, a.d * b.d);
    else if (op === '*') r = new Rational(a.n * b.n, a.d * b.d);
    else if (op === '/') r = new Rational(a.n * b.d, a.d * b.n);
    else if (op === 'pow') {
      if (a.d !== 1n || b.d !== 1n)
        throw new TypeError('integer operands required');
      if (b.n < 0n) throw new RangeError('negative exponent');
      return a.n ** b.n;
    } else if (op === 'quot' || op === 'rem') {
      if (a.d !== 1n || b.d !== 1n)
        throw new TypeError('integer operands required');
      return op === 'quot' ? a.n / b.n : a.n % b.n;
    } else throw new Error('unknown operator ' + op);
    return convert(r, t);
  }
  if (t.startsWith('Complex')) {
    a = convert(a, t);
    b = convert(b, t);
    const r = t === 'Complex64' ? Math.fround : (x) => x;
    if (op === '==' || op === '!=') {
      const e = a.real === b.real && a.imaginary === b.imaginary;
      return op === '==' ? e : !e;
    }
    if (op === '+')
      return new Complex(r(a.real + b.real), r(a.imaginary + b.imaginary));
    if (op === '-')
      return new Complex(r(a.real - b.real), r(a.imaginary - b.imaginary));
    if (op === '*')
      return new Complex(
          r(r(a.real * b.real) - r(a.imaginary * b.imaginary)),
          r(r(a.real * b.imaginary) + r(a.imaginary * b.real)),
      );
    if (op === '/') {
      const d = r(r(b.real * b.real) + r(b.imaginary * b.imaginary));
      return new Complex(
          r(r(r(a.real * b.real) + r(a.imaginary * b.imaginary)) / d),
          r(r(r(a.imaginary * b.real) - r(a.real * b.imaginary)) / d),
      );
    }
  }
  if (['==', '!=', '<', '<=', '>', '>='].includes(op))
    return compare(op, a, b);
  const v =
      op === '+' ? a + b : op === '-' ? a - b : op === '*' ? a * b : a / b;
  return t === 'Float32' ? Math.fround(v) : v;
}
function compare(op, a, b) {
  return op === '=='
    ? a === b
    : op === '!='
      ? a !== b
      : op === '<'
        ? a < b
        : op === '<='
          ? a <= b
          : op === '>'
            ? a > b
            : a >= b;
}
// Handles are values only adapters create, passed along unopened. The schema
// registers each one as it crosses into LawSpec, so the runtime knows it: it
// is equal only to itself, has no portable order, and renders as a stable
// label numbered by first appearance in the process (Jobs#1).
const handleLabels = new WeakMap();
const primitiveHandleLabels = new Map();
const handleCounts = new Map();
const handleTable = (value) =>
  (typeof value === 'object' && value !== null) || typeof value === 'function'
    ? handleLabels
    : primitiveHandleLabels;

/** Registers a handle of the named type; returns it unchanged. */
export function handle(value, name) {
  const table = handleTable(value);
  if (!table.has(value)) {
    const short = name.split('::').pop();
    const count = (handleCounts.get(short) ?? 0) + 1;
    handleCounts.set(short, count);
    table.set(value, short + '#' + count);
  }
  return value;
}

export function isHandle(value) {
  return handleTable(value).has(value);
}

export function equal(a, b, ta, tb) {
  if (isHandle(a) || isHandle(b)) return a === b;
  if (ta.startsWith('Either ') && tb.startsWith('Either ')) {
    if (a.tag !== b.tag) return false;
    const index = a.tag === 'Either::Left' ? 0 : 1;
    return equal(
        a.fields[0],
        b.fields[0],
        eitherArguments(ta)[index],
        eitherArguments(tb)[index],
    );
  }
  if (ta.startsWith('Maybe ') && tb.startsWith('Maybe ')) {
    return (
      a.tag === b.tag &&
        (a.tag === 'Maybe::Nothing' ||
          equal(a.fields[0], b.fields[0], ta.slice(6), tb.slice(6)))
    );
  }
  if (ta.startsWith('List ') && tb.startsWith('List ')) {
    return (
      a.length === b.length &&
        a.every((value, index) =>
            equal(value, b[index], ta.slice(5), tb.slice(5)),
        )
    );
  }
  if (ta === 'Bytes' && tb === 'Bytes')
    return a.length === b.length && a.every((c, i) => c === b[i]);
  if (
      ['Float32', 'Float64', 'Complex64', 'Complex128'].includes(ta) &&
      ['Float32', 'Float64', 'Complex64', 'Complex128'].includes(tb)
  )
    return binary('==', a, b, ta, tb);
  if (exactType(ta) && exactType(tb)) {
    a = ratio(a);
    b = ratio(b);
    return a.n === b.n && a.d === b.d;
  }
  if (a instanceof Complex && b instanceof Complex)
    return a.real === b.real && a.imaginary === b.imaginary;
  if (a instanceof Presence && b instanceof Presence)
    return (
      a.kind === b.kind &&
        a.present === b.present &&
        (!a.present ||
          equal(
              a.value,
              b.value,
              ta.slice(ta.indexOf(' ') + 1),
              tb.slice(tb.indexOf(' ') + 1),
          ))
    );
  if (a instanceof Raw && b instanceof Raw)
    return (
      a.kind === b.kind &&
        a.units.length === b.units.length &&
        a.units.every((c, i) => c === b.units[i])
    );
  return a === b;
}
const ORDERING = 'lawspec.collections::type::Ordering::';
const sign = (x) => (x > 0 ? 1 : x < 0 ? -1 : 0);

// The portable total order: -1, 0 or 1. Exact numbers by value, text by code
// point, raw sequences by unit, false before true, absence before presence,
// lists element by element, Nothing before Just, and other data by
// constructor identity, then fields left to right.
export function compareValues(a, b) {
  // Handles have no order: one equals only itself.
  if (isHandle(a) && isHandle(b)) {
    if (a === b) return 0;
    throw new TypeError('handles have no portable order');
  }
  if (typeof a === 'boolean' && typeof b === 'boolean') return sign(Number(a) - Number(b));
  if (typeof a === 'string' && typeof b === 'string') {
    const x = [...a], y = [...b];
    for (let i = 0; i < Math.min(x.length, y.length); ++i) {
      const order = sign(x[i].codePointAt(0) - y[i].codePointAt(0));
      if (order) return order;
    }
    return sign(x.length - y.length);
  }
  if (a instanceof Raw && b instanceof Raw) return compareValues([...a.units], [...b.units]);
  if (a === UNIT && b === UNIT) return 0;
  if (a instanceof Presence && b instanceof Presence) {
    if (a.present !== b.present) return a.present ? 1 : -1;
    return a.present ? compareValues(a.value, b.value) : 0;
  }
  if (Array.isArray(a) && Array.isArray(b)) {
    for (let i = 0; i < Math.min(a.length, b.length); ++i) {
      const order = compareValues(a[i], b[i]);
      if (order) return order;
    }
    return sign(a.length - b.length);
  }
  if (a instanceof DataValue && b instanceof DataValue) {
    if (a.tag !== b.tag) {
      if (a.tag === 'Maybe::Nothing' && b.tag === 'Maybe::Just') return -1;
      if (a.tag === 'Maybe::Just' && b.tag === 'Maybe::Nothing') return 1;
      return a.tag < b.tag ? -1 : 1;
    }
    return compareValues([...a.fields], [...b.fields]);
  }
  if (typeof a === 'number' && typeof b === 'number') return sign(a - b);
  const x = ratio(a), y = ratio(b);
  const difference = x.n * y.d - y.n * x.d;
  return difference > 0n ? 1 : difference < 0n ? -1 : 0;
}

export function helper(n, args, types, bits = 64) {
  const x = args[0];
  if (n === 'checked') return true;
  if (n === 'select') return args[0] ? args[1] : args[2];
  if (n === 'compare')
    return new DataValue(ORDERING + ['Less', 'Equal', 'Greater'][compareValues(args[0], args[1]) + 1], []);
  if (n === 'length')
    return BigInt(
        typeof x === 'string'
          ? [...x].length
          : x instanceof Raw
            ? x.units.length
            : x.length,
    );
  if (n === 'isPresent') return x.present;
  if (n === 'presentValue') {
    if (!x.present) throw new Error('absent presence value');
    return x.value;
  }

  if (n === 'real') return x.real;
  if (n === 'imag') return x.imaginary;
  if (n === 'negate') {
    if (exactType(types[0])) return binary('-', 0n, x, 'BigInt', types[0]);
    return x instanceof Complex ? new Complex(-x.real, -x.imaginary) : -x;
  }
  if (n === 'quot' || n === 'rem' || n === 'pow') return binary(n, ...args, ...types);
  if (n === 'isNaN') return Number.isNaN(x);
  if (n === 'isInfinite') return x === Infinity || x === -Infinity;
  if (n === 'isFinite') return Number.isFinite(x);
  if (n === 'isNegativeZero') return Object.is(x, -0);
  if (n === 'round') {
    const scale = BigInt(convert(args[1], 'Int32', bits)),
        factor =
            scale >= 0n
              ? new Rational(10n ** scale)
              : new Rational(1n, 10n ** -scale),
        v = ratio(x),
        a = new Rational(v.n * factor.n, v.d * factor.d);
    let q = a.n / a.d,
        r = a.n % a.d;
    const abs = r < 0n ? -r : r;
    if (abs * 2n > a.d || (abs * 2n === a.d && q % 2n !== 0n))
      q += a.n < 0n ? -1n : 1n;
    return decimal(new Rational(q * factor.d, factor.n));
  }
  return convert(x, n, bits);
}

// Round an exact rational directly to IEEE precision, including subnormal ties.
function exactFloat(r, t) {
  if (r.n === 0n) return 0;
  const negative = r.n < 0n,
      n = negative ? -r.n : r.n,
      d = r.d,
      single = t === 'Float32';
  const p = single ? 24 : 53,
      bias = single ? 127 : 1023,
      emin = 1 - bias,
      emax = bias;
  let e = n.toString(2).length - d.toString(2).length;
  if (e >= 0 ? n < d << BigInt(e) : n << BigInt(-e) < d) e--;
  if (e > emax) return negative ? -Infinity : Infinity;
  const scale = Math.max(e, emin) - (p - 1);
  const num = scale < 0 ? n << BigInt(-scale) : n,
      den = scale > 0 ? d << BigInt(scale) : d;
  let q = num / den,
      rem = num % den;
  if (rem * 2n > den || (rem * 2n === den && q % 2n !== 0n)) q++;
  e = Math.max(e, emin);
  if (q === 1n << BigInt(p)) {
    q >>= 1n;
    e++;
  }
  if (e > emax) return negative ? -Infinity : Infinity;
  const hidden = 1n << BigInt(p - 1),
      exponent = q < hidden ? 0 : e + bias,
      mantissa = q < hidden ? q : q - hidden;
  const bits =
      (BigInt(negative ? 1 : 0) << BigInt(single ? 31 : 63)) |
      (BigInt(exponent) << BigInt(p - 1)) |
      mantissa;
  const view = new DataView(new ArrayBuffer(8));
  if (single) {
    view.setUint32(0, Number(bits));
    return view.getFloat32(0);
  }
  view.setBigUint64(0, bits);
  return view.getFloat64(0);
}

// Abilities (docs/explanation/abilities.md). Handlers travel in the symbols
// Map generated code passes to every definition: that Map is the evidence of
// evidence-passing compilation. A law installs one handler per ability; an
// operation finds the handler of its ability there. The Fail ability's
// handlers abort, so raise throws a Failure and attempt catches it.
const HANDLERS = '_lawspec_handlers';

export class Failure extends Error {
  constructor(ability, value) {
    super(`failed with ${String(value)} (${ability})`);
    this.ability = ability;
    this.value = value;
  }
}

export function installHandlers(symbols, handlers) {
  const table = new Map(symbols.get(HANDLERS) ?? []);
  for (const [key, value] of Object.entries(handlers)) table.set(key, value);
  symbols.set(HANDLERS, table);
  return symbols;
}

export function handler(symbols, ability) {
  const table = symbols instanceof Map ? symbols.get(HANDLERS) : undefined;
  if (table === undefined || !table.has(ability))
    throw new Error(`no handler for the ability ${ability}: a law names one with \`using\`, or runs under each lawful handler`);
  return table.get(ability);
}

export function raiseFailure(ability, value) {
  throw new Failure(ability, value);
}

export function attempt(ability, body, right, left) {
  let value;
  try {
    value = body();
  } catch (error) {
    if (error instanceof Failure && error.ability === ability) return left(error.value);
    throw error;
  }
  return right(value);
}

export async function attemptAsync(ability, body, right, left) {
  let value;
  try {
    value = await body();
  } catch (error) {
    if (error instanceof Failure && error.ability === ability) return left(error.value);
    throw error;
  }
  return right(value);
}

// The schema a handler's values cross with: the bound native types when
// lawspec.json binds them (the native bindings module sets it).
let boundHandlerSchema = null;
export function setHandlerSchema(schema) {
  boundHandlerSchema = schema;
}
export function handlerSchema(fallback) {
  return boundHandlerSchema ?? fallback;
}

// handle e with h end: runs body with these handlers installed, then puts
// back the ones they replaced.
export function withHandlers(symbols, handlers, body) {
  const previous = symbols.get(HANDLERS);
  const table = new Map(previous ?? []);
  for (const [key, value] of Object.entries(handlers)) table.set(key, value);
  symbols.set(HANDLERS, table);
  try {
    return body();
  } finally {
    if (previous === undefined) symbols.delete(HANDLERS);
    else symbols.set(HANDLERS, previous);
  }
}

// Native code (an adapter, or a production handler) throws Fail to fail
// with a value of the failure type its signature names: `fails with E`.
export class Fail extends Error {
  constructor(value) {
    super(`failed with ${String(value)}`);
    this.value = value;
  }
}

// Calls native code that may fail: a Fail it throws, or an error
// lawspec.json maps to a failure ([class, make] pairs), becomes a failure of
// the ability.
export function nativeFailures(ability, convert, body, mapped = []) {
  try {
    return body();
  } catch (error) {
    if (error instanceof Fail) throw new Failure(ability, convert(error.value));
    for (const [kind, make] of mapped) {
      if (error instanceof kind) throw new Failure(ability, make(error));
    }
    throw error;
  }
}

export function countCalls(recording, operation, matches = null) {
  if (recording === null || typeof recording !== 'object' || !Array.isArray(recording.calls))
    throw new TypeError('calls of needs a recording handler: `using recording`');
  return recording.calls.filter(([name, args]) => name === operation && (matches === null || matches(args))).length;
}

export function unitResult(value) {
  return value === undefined ? UNIT : validate(value, 'Unit');
}

// Domain generation operates on exact values independently of test frameworks.
export function sample(t, seed, bits = 64) {
  let n = BigInt(seed);
  const next = () =>
      (n = BigInt.asUintN(
          256,
          n * 6364136223846793005n + 1442695040888963407n,
      ));
  for (let j = 0; j < 8; j++) next();
  if (t.startsWith('Nullable ') || t.startsWith('Optional ')) {
    const [kind, ...rest] = t.split(' ');
    return new Presence(
        kind,
        !!(seed % 2),
        seed % 2
          ? sample(rest.join(' '), Math.trunc(seed / 2), bits)
          : undefined,
    );
  }
  if (integerType(t)) {
    let [lo, hi] = bounds(t, bits);
    lo ??= -(2n ** 256n);
    hi ??= 2n ** 256n;
    return convert(lo + (n % (hi - lo + 1n)), t, bits);
  }
  if (t === 'Bool') return !!(seed % 2);
  if (t === 'Decimal')
    return new Decimal(n - 2n ** 255n, BigInt((seed % 41) - 20));
  if (t === 'Rational')
    return new Rational(n - 2n ** 255n, (next() % 2n ** 128n) + 1n);
  if (t.startsWith('Float'))
    return literal({
      type: t,
      bits: BigInt.asUintN(t === 'Float32' ? 32 : 64, n)
          .toString(16)
          .padStart(t === 'Float32' ? 8 : 16, '0'),
    });
  if (t.startsWith('Complex')) {
    const c = t === 'Complex64' ? 'Float32' : 'Float64';
    return new Complex(sample(c, seed, bits), sample(c, seed + 1, bits));
  }
  if (t === 'Unit') return UNIT;
  if (t === 'Null') return null;
  if (t === 'Undefined') return undefined;
  if (t === 'Symbol') return Symbol('same');
  const maximum =
      t === 'Bytes'
        ? 256
        : ['Utf16Text', 'CodeUnit16'].includes(t)
          ? 65536
          : 1114112;
  const unit = () => {
    let c;
    do {
      c = Number(next() % BigInt(maximum));
    } while (['Char', 'Text'].includes(t) && c >= 55296 && c <= 57343);
    return c;
  };
  if (t === 'Char') return String.fromCodePoint(unit());
  if (['CodePoint', 'CodeUnit16'].includes(t)) return unit();
  const xs = Array.from({length: Number(n % 40n)}, unit);
  if (t === 'Text') return String.fromCodePoint(...xs);
  if (t === 'Bytes') return new Uint8Array(xs);
  return new Raw(t, xs);
}
const floorRatio = (r) =>
    r.n / r.d - (r.n < 0n && r.n % r.d !== 0n ? 1n : 0n);
const ceilRatio = (r) => -floorRatio(new Rational(-r.n, r.d));
export function domainCandidates(t, seed, bits, restrictions, hints) {
  let candidates = [];
  for (const hint of hints) {
    try {
      candidates.push(convert(hint, t, bits));
    } catch {}
  }
  if (integerType(t)) {
    let [lo, hi] = bounds(t, bits);
    for (const [op, value] of restrictions) {
      const r = ratio(value);
      if (['>', '>=', '=='].includes(op)) {
        const v = op === '>' ? floorRatio(r) + 1n : ceilRatio(r);
        lo = lo === null || v > lo ? v : lo;
      }
      if (['<', '<=', '=='].includes(op)) {
        const v = op === '<' ? ceilRatio(r) - 1n : floorRatio(r);
        hi = hi === null || v < hi ? v : hi;
      }
    }
    if (lo !== null && hi !== null && lo > hi) return [];
    const lower =
        lo ?? ((hi ?? 0n) < 0n ? (hi ?? 0n) - 2n ** 256n : -(2n ** 256n)),
        upper =
            hi ?? ((lo ?? 0n) > 0n ? (lo ?? 0n) + 2n ** 256n : 2n ** 256n);
    candidates.push(lower, upper, 0n, 1n, -1n, lower + 1n, upper - 1n);
    let n = BigInt(seed);
    for (let j = 0; j < 8; j++) {
      n = BigInt.asUintN(
          256,
          n * 6364136223846793005n + 1442695040888963407n,
      );
      candidates.push(lower + (n % (upper - lower + 1n)));
    }
    candidates = candidates
        .filter(
        (v) =>
            ['number', 'bigint'].includes(typeof v) &&
            BigInt(v) >= lower &&
            BigInt(v) <= upper,
      )
        .map((v) => convert(v, t, bits));
  } else
    for (let j = 0; j < 8; j++)
      candidates.push(sample(t, seed + j * 7919, bits));
  if (candidates.length) {
    const offset =
        ((seed % candidates.length) + candidates.length) % candidates.length;
    candidates = [
      ...candidates.slice(offset),
      ...candidates.slice(0, offset),
    ];
  }
  return candidates;
}
export function generateTuple(domains, seed, attempts, prefix = []) {
  let used = 0,
      lastPrefix = prefix;
  const search = (values) => {
    lastPrefix = values;
    if (values.length === domains.length) return values;
    if (used >= attempts) return null;
    used++;
    const [candidates, accept] = domains[values.length];
    for (const value of candidates(values, seed + used * 7919)) {
      if (used >= attempts) break;
      used++;
      const next = [...values, value];
      if (accept(next)) {
        const result = search(next);
        if (result !== null) return result;
      }
    }
    return null;
  };
  while (used < attempts) {
    const result = search([...prefix]);
    if (result !== null) return result;
  }
  throw new Error(
      `refinement-generation-exhausted after ${used} attempts; ` +
        `prefix=${lastPrefix.map(String)}; seed=${seed}`,
  );
}
export function requireContract(condition, context) {
  if (condition !== true) throw new Error(context);
}
export function refinedCase(
    domains,
    seed,
    attempts,
    shrinks,
    check,
    context = 'refinement',
) {
  let values;
  try {
    values = generateTuple(domains, seed, attempts);
  } catch (error) {
    throw new Error(`${context}: ${error.message}`, {cause: error});
  }
  try {
    check(values);
  } catch (original) {
    let best = values,
        budget = shrinks;
    for (let i = 0; i < best.length; i++) {
      const current = best[i],
          integer =
              typeof current === 'bigint' ||
              (typeof current === 'number' && Number.isSafeInteger(current));
      const candidates = domains[i][0](best.slice(0, i), 0);
      if (integer) {
        const initial = BigInt(current);
        let reduced = initial;
        candidates.unshift(
            typeof current === 'number' ? 0 : 0n,
            typeof current === 'number'
              ? Math.sign(current)
              : initial > 0n
                ? 1n
                : -1n,
        );
        while (reduced > 1n || reduced < -1n) {
          reduced /= 2n;
          candidates.splice(
              2,
              0,
              typeof current === 'number' ? Number(reduced) : reduced,
          );
        }
      }
      for (const candidate of candidates) {
        if (budget-- <= 0) break;
        if (complexity(candidate) >= complexity(best[i])) continue;
        const prefix = [...best.slice(0, i), candidate];
        if (!domains[i][1](prefix)) continue;
        let trial;
        try {
          trial = generateTuple(
              domains,
              seed,
              Math.min(attempts, 100),
              prefix,
          );
        } catch (error) {
          if (error.message.startsWith('refinement-generation-exhausted'))
            continue;
          throw error;
        }
        try {
          check(trial);
        } catch {
          best = trial;
        }
      }
    }
    throw new Error(
        `${context}: ${original.message}; ` +
          `refined counterexample=${best.map(String)}; seed=${seed}`,
        {cause: original},
    );
  }
}

// refinedCase for checks that await async adapters.
export async function refinedCaseAsync(
    domains,
    seed,
    attempts,
    shrinks,
    check,
    context = 'refinement',
) {
  let values;
  try {
    values = generateTuple(domains, seed, attempts);
  } catch (error) {
    throw new Error(`${context}: ${error.message}`, {cause: error});
  }
  try {
    await check(values);
  } catch (original) {
    let best = values,
        budget = shrinks;
    for (let i = 0; i < best.length; i++) {
      const current = best[i],
          integer =
              typeof current === 'bigint' ||
              (typeof current === 'number' && Number.isSafeInteger(current));
      const candidates = domains[i][0](best.slice(0, i), 0);
      if (integer) {
        const initial = BigInt(current);
        let reduced = initial;
        candidates.unshift(
            typeof current === 'number' ? 0 : 0n,
            typeof current === 'number'
              ? Math.sign(current)
              : initial > 0n
                ? 1n
                : -1n,
        );
        while (reduced > 1n || reduced < -1n) {
          reduced /= 2n;
          candidates.splice(
              2,
              0,
              typeof current === 'number' ? Number(reduced) : reduced,
          );
        }
      }
      for (const candidate of candidates) {
        if (budget-- <= 0) break;
        if (complexity(candidate) >= complexity(best[i])) continue;
        const prefix = [...best.slice(0, i), candidate];
        if (!domains[i][1](prefix)) continue;
        let trial;
        try {
          trial = generateTuple(
              domains,
              seed,
              Math.min(attempts, 100),
              prefix,
          );
        } catch (error) {
          if (error.message.startsWith('refinement-generation-exhausted'))
            continue;
          throw error;
        }
        try {
          await check(trial);
        } catch {
          best = trial;
        }
      }
    }
    throw new Error(
        `${context}: ${original.message}; ` +
          `refined counterexample=${best.map(String)}; seed=${seed}`,
        {cause: original},
    );
  }
}

function complexity(value) {
  if (value instanceof Presence)
    return value.present ? 1n + complexity(value.value) : 0n;
  if (value instanceof Raw) return BigInt(value.units.length);
  if (value instanceof Uint8Array) return BigInt(value.length);
  if (typeof value === 'string') return BigInt([...value].length);
  if (typeof value === 'bigint') return value < 0n ? -value : value;
  if (typeof value === 'number') {
    if (Number.isSafeInteger(value)) return BigInt(Math.abs(value));
    const view = new DataView(new ArrayBuffer(8));
    view.setFloat64(0, Math.abs(value));
    return view.getBigUint64(0);
  }
  if (typeof value === 'boolean') return value ? 1n : 0n;
  if (value instanceof Decimal || value instanceof Rational) {
    const r = ratio(value);
    return (r.n < 0n ? -r.n : r.n) + r.d - 1n;
  }
  if (value instanceof Complex)
    return complexity(value.real) + complexity(value.imaginary);
  if (typeof value === 'symbol') return 1n;
  return 0n;
}

export function construct(tag, fields) {
  if (
      (tag === 'Maybe::Nothing' && fields.length === 0) ||
      (['Maybe::Just', 'Either::Left', 'Either::Right'].includes(tag) &&
        fields.length === 1)
  ) {
    return new DataValue(tag, fields);
  }
  if (tag === 'List::Nil' && fields.length === 0) return [];
  if (
      tag === 'List::Cons' &&
      fields.length === 2 &&
      Array.isArray(fields[1])
  ) {
    return [fields[0], ...fields[1]];
  }
  throw new TypeError('invalid constructor or arity: ' + tag);
}

export function allElements(value, predicate) {
  if (!Array.isArray(value))
    throw new TypeError('expected List in element predicate');
  for (let index = 0; index < value.length; index++) {
    try {
      const accepted = predicate(value[index]);
      if (typeof accepted !== 'boolean') {
        throw new TypeError('element predicate must return Bool');
      }
      if (!accepted) return false;
    } catch (error) {
      throw new Error(`List element ${index}: ${error.message}`, {
        cause: error,
      });
    }
  }
  return true;
}

export function matchList(value, branches) {
  if (!Array.isArray(value)) throw new TypeError('expected List in match');
  for (let index = 0; index < value.length; index++) {
    if (!Object.hasOwn(value, index)) {
      throw new TypeError('List cannot contain array holes');
    }
  }
  const tag = value.length === 0 ? 'List::Nil' : 'List::Cons';
  const branch = branches.find(([candidate]) => candidate === tag);
  if (!branch) throw new TypeError('missing match branch: ' + tag);
  return value.length === 0
    ? branch[1]()
    : branch[1](value[0], value.slice(1));
}

export function matchValue(value, branches) {
  if (Array.isArray(value)) return matchList(value, branches);
  if (!(value instanceof DataValue))
    throw new TypeError('expected data in match');
  const arity =
      value.tag === 'Maybe::Nothing'
        ? 0
        : ['Maybe::Just', 'Either::Left', 'Either::Right'].includes(value.tag)
          ? 1
          : -1;
  if (value.fields.length !== arity) {
    throw new TypeError('invalid match constructor or arity');
  }
  const branch = branches.find(([tag]) => tag === value.tag);
  if (!branch) throw new TypeError('missing match branch: ' + value.tag);
  return branch[1](...value.fields);
}

// Decode the compiler's parenthesized two-argument runtime type key.
function eitherArguments(type) {
  const args = [];
  let depth = 0;
  let start = 0;
  for (let index = 7; index < type.length; index++) {
    const char = type[index];
    if (char === '(') {
      if (depth === 0) start = index + 1;
      depth++;
    } else if (char === ')') {
      if (--depth < 0) throw new TypeError('invalid Either type key');
      if (depth === 0) args.push(type.slice(start, index));
    } else if (depth === 0 && char !== ' ') {
      throw new TypeError('invalid Either type key');
    }
  }
  if (depth !== 0 || args.length !== 2 || args.some((arg) => !arg.trim())) {
    throw new TypeError('invalid Either type key');
  }
  return args;
}

// Workflow runtime. A workflow runs under a runtime: a clock, a seeded
// random source, a trace of what happened, and the state of stateful stages.
// The runtime travels in the symbols Map every generated function takes;
// without one, the default runtime applies (real time, unless the tests
// installed a virtual clock). Durations are bigint microseconds.

const WORKFLOW = '\0lawspec.workflow';
const MASK64 = (1n << 64n) - 1n;

export class RealClock {
  virtual = false;
  now() { return BigInt(Math.round(performance.now() * 1000)); }
  /** Waits without blocking, for asynchronous workflows. */
  sleepAsync(micros) { return new Promise((resolve) => setTimeout(resolve, Number(micros) / 1000)); }
  sleep(micros) {
    const until = performance.now() + Number(micros) / 1000;
    while (performance.now() < until) { /* synchronous workflows block */ }
  }
}

/** Sleeping advances the clock and returns at once. */
export class VirtualClock {
  virtual = true;
  time;
  constructor(start = 0n) { this.time = BigInt(start); }
  now() { return this.time; }
  sleep(micros) { this.time += BigInt(micros); }
  sleepAsync(micros) { this.sleep(micros); return Promise.resolve(); }
}

/** The same sequence on every target for the same seed. */
export class SplitMix64 {
  state;
  constructor(seed = 0n) { this.state = BigInt(seed) & MASK64; }
  next() {
    this.state = (this.state + 0x9E3779B97F4A7C15n) & MASK64;
    let z = this.state;
    z = ((z ^ (z >> 30n)) * 0xBF58476D1CE4E5B9n) & MASK64;
    z = ((z ^ (z >> 27n)) * 0x94D049BB133111EBn) & MASK64;
    return z ^ (z >> 31n);
  }
  /** Uniform in [0, bound); 0 when bound is 0. */
  below(bound) { return bound > 0n ? this.next() % bound : 0n; }
}

/**
 * gates: whether rate limits, breakers, bulkheads and caches apply. The
 * runtime generated tests install has them off: a workflow law calls the
 * workflow and its composition, which would see each other's state.
 */
export class WorkflowRuntime {
  clock;
  random;
  trace;
  state;
  gates;
  frames;
  constructor(clock = new RealClock(), seed = 0n, gates = true) {
    this.clock = clock;
    this.random = new SplitMix64(seed);
    this.trace = [];
    this.state = new Map();
    this.gates = gates;
    // A frame per running workflow: the undos of its completed stages.
    this.frames = [];
  }
  /** A symbols Map that runs workflows under this runtime. */
  context(symbols = new Map()) {
    symbols.set(WORKFLOW, this);
    return symbols;
  }
}

let defaultRuntime = null;
const CLOCK_KEY = 'lawspec.time::ability::Clock';
const CLOCK_VIEW = '\0lawspec.workflow.clock';

// The native Duration a Clock handler's sleep takes: the data module's
// Duration class, loaded beside the runtime when the program has one (a
// spec handler, such as the virtual clock, accepts only that class); else an
// object with its value, which the default handler reads.
let durationClass = null;
let durationLoad = null;
function loadDurationClass() {
  if (durationLoad === null) {
    try {
      const extension = String(import.meta.url).endsWith('.mjs') ? '.mjs' : '.js';
      durationLoad = import('./lawspec_data' + extension).then((module) => {
        if (typeof module.Duration === 'function') durationClass = module.Duration;
      }, () => {});
    } catch {
      durationLoad = Promise.resolve();
    }
  }
  return durationLoad;
}
loadDurationClass();

/** A Clock handler's native Duration of micros microseconds. */
export function nativeDuration(micros) {
  const value = BigInt(micros);
  return durationClass !== null ? new durationClass(value) : {value};
}

/** Whether a Clock handler is real time (the default handler marks itself). */
export function realTimeClock(handler) {
  return handler !== null && handler !== undefined && handler.realTime === true;
}

/**
 * A workflow runtime's clock read through the Clock ability: the handler a
 * law installs (the virtual clock, or the default real one). A handler that
 * is not real time (realTime === true) is virtual: waits pass at once, and
 * timeouts and hedges count only the time it reports.
 */
export class AbilityClock {
  handler;
  virtual;
  constructor(handler) {
    this.handler = handler;
    this.virtual = !realTimeClock(handler);
  }
  now() {
    const instant = this.handler.now();
    if (instant instanceof DataValue) return BigInt(instant.fields[0]);
    if (instant !== null && typeof instant === 'object' && 'value' in instant) return BigInt(instant.value);
    return BigInt(instant);
  }
  sleep(micros) {
    this.handler.sleep(nativeDuration(micros));
  }
  /** Waits without blocking on a real-time handler; at once on a virtual one. */
  async sleepAsync(micros) {
    if (this.virtual) {
      await loadDurationClass();
      this.sleep(micros);
      return;
    }
    await new Promise((resolve) => setTimeout(resolve, Number(micros) / 1000));
  }
}

/**
 * Make the default runtime virtual, as generated tests do. Timeouts and
 * hedges stay on: they count virtual time (see scoped, timed and hedged).
 */
export function useVirtualClock(seed = 0n) {
  defaultRuntime = new WorkflowRuntime(new VirtualClock(), seed, false);
}

export function workflowRuntime(symbols) {
  const runtime = symbols instanceof Map ? symbols.get(WORKFLOW) : undefined;
  if (runtime !== undefined) return runtime;
  if (defaultRuntime === null) defaultRuntime = new WorkflowRuntime();
  // Workflow time is the Clock ability's: where a law has installed a Clock
  // handler, the default runtime waits and times out on it. The view shares
  // the runtime's state and trace, and is the same object for the same
  // context and handler.
  const table = symbols instanceof Map ? symbols.get(HANDLERS) : undefined;
  const clock = table === undefined ? undefined : table.get(CLOCK_KEY);
  if (clock === undefined || clock === null) return defaultRuntime;
  let view = symbols.get(CLOCK_VIEW);
  if (view === undefined || view[0] !== clock || view[1] !== defaultRuntime) {
    const under = Object.assign(Object.create(Object.getPrototypeOf(defaultRuntime)), defaultRuntime);
    under.clock = new AbilityClock(clock);
    view = [clock, defaultRuntime, under];
    symbols.set(CLOCK_VIEW, view);
  }
  return view[2];
}

function fibonacci(n) {
  let a = 1n, b = 1n;
  for (let i = 1n; i < n; i++) [a, b] = [b, a + b];
  return a;
}

/**
 * The delay before attempt (2 or more), before jitter. A strategy is
 * ['immediate'], ['fixed', d], ['linear', d, step],
 * ['exponential', d, factor, cap or null], ['fibonacci', d] or
 * ['custom', decide], where decide(attempt, error, previous) returns a delay
 * or null to stop.
 */
export function retryDelay(strategy, attempt) {
  const n = BigInt(attempt) - 1n;
  switch (strategy[0]) {
    case 'immediate': return 0n;
    case 'fixed': return strategy[1];
    case 'linear': return strategy[1] + strategy[2] * (n - 1n);
    case 'exponential': {
      const delay = strategy[1] * strategy[2] ** (n - 1n);
      return strategy[3] === null || delay < strategy[3] ? delay : strategy[3];
    }
    case 'fibonacci': return strategy[1] * fibonacci(n);
    default: throw new Error('unknown retry strategy: ' + strategy[0]);
  }
}

/**
 * Full: [0, delay]; equal: delay/2 + [0, delay/2]; decorrelated:
 * [base, previous * 3], capped at delay.
 */
export function jittered(jitter, delay, previous, base, random) {
  if (jitter === 'full') return random.below(delay + 1n);
  if (jitter === 'equal') {
    const half = delay / 2n;
    return half + random.below(delay - half + 1n);
  }
  if (jitter === 'decorrelated') {
    const high = previous * 3n > base ? previous * 3n : base;
    const value = base + random.below(high - base + 1n);
    return value < delay ? value : delay;
  }
  return delay;
}

const STAGE_FAILURE = 'lawspec.resilience::type::StageFailure::';
const GATE = 'lawspec.resilience::type::Gate::';
const FAILURES = {breaker: 'CircuitOpen', limit: 'RateLimited', bulkhead: 'Saturated'};

export function stageFailure(kind) {
  return new DataValue('Either::Left', [new DataValue(STAGE_FAILURE + kind, [])]);
}

/**
 * A gate is a stateful policy: start(now) gives its state, admit(state, now)
 * a Step of the next state and a Gate (Admit, WaitFor or Reject), and
 * finish(state, now, succeeded) the state after the call. wait is null to
 * fail at once when not admitted, or the most it waits (-1n for no bound).
 * Returns null when admitted, or the failure to give instead.
 */
function passGate(runtime, policy, gate) {
  const key = policy.key + '/' + gate.kind;
  let waited = 0n;
  for (;;) {
    const now = runtime.clock.now();
    const state = runtime.state.has(key) ? runtime.state.get(key) : gate.start(now);
    const step = gate.admit(state, now);
    runtime.state.set(key, step.fields[0]);
    const decision = step.fields[1];
    if (decision.tag === GATE + 'Admit') return null;
    if (decision.tag === GATE + 'Reject' || gate.wait === null) return FAILURES[gate.kind];
    const delay = decision.fields[0];
    if (gate.wait >= 0n && waited + delay > gate.wait) return FAILURES[gate.kind];
    runtime.trace.push(['wait', policy.stage, delay]);
    runtime.clock.sleep(delay);
    waited += delay;
  }
}

function finishGate(runtime, policy, gate, succeeded) {
  if (gate.finish === null) return;
  const key = policy.key + '/' + gate.kind;
  runtime.state.set(key, gate.finish(runtime.state.get(key), runtime.clock.now(), succeeded));
}

/**
 * Runs a stage's attempts under its policy; a Left is a failure. attempt()
 * returns the stage's Either; key is its input, for the cache.
 */
export function runStage(symbols, given, attempt, ...input) {
  // The key is optional (a rest parameter keeps it so for TypeScript), and a
  // policy built by hand may leave out what it does not use.
  const key = input[0];
  const policy = {key: given.stage, gates: [], cache: null, wraps: false, timeout: null, compensate: null, hedge: null, ...given};
  const runtime = workflowRuntime(symbols);
  const gates = runtime.gates ? policy.gates : [];
  let cached = null;
  if (policy.cache !== null && runtime.gates) {
    const cacheKey = policy.key + '/cache';
    if (!runtime.state.has(cacheKey)) runtime.state.set(cacheKey, []);
    cached = runtime.state.get(cacheKey);
    const now = runtime.clock.now();
    for (const [entry, value, expires] of cached) {
      if (now < expires && equalValues(entry, key)) {
        runtime.trace.push(['cached', policy.stage, 0n]);
        return value;
      }
    }
  }
  for (let i = 0; i < gates.length; i++) {
    const failure = passGate(runtime, policy, gates[i]);
    if (failure !== null) {
      for (const passed of gates.slice(0, i)) finishGate(runtime, policy, passed, false);
      return stageFailure(failure);
    }
  }
  const result = attempts(runtime, policy, attempt);
  const succeeded = !(result instanceof DataValue && result.tag === 'Either::Left');
  for (const gate of gates) finishGate(runtime, policy, gate, succeeded);
  if (succeeded && policy.compensate !== null && runtime.frames.length > 0) {
    const value = result.fields[0];
    runtime.frames[runtime.frames.length - 1].push([policy.stage, () => policy.compensate(value)]);
  }
  if (cached !== null && succeeded) {
    const kept = cached.filter(([entry]) => !equalValues(entry, key));
    cached.length = 0;
    cached.push(...kept, [key, result, runtime.clock.now() + policy.cache]);
  }
  return result;
}

/**
 * Runs a workflow whose stages compensate: when it fails, the undos of its
 * completed stages run, last first.
 */
export function runWorkflow(symbols, attempt) {
  const runtime = workflowRuntime(symbols);
  const frame = [];
  runtime.frames.push(frame);
  let result;
  try {
    result = attempt();
  } finally {
    runtime.frames.pop();
  }
  if (result instanceof DataValue && result.tag === 'Either::Left') {
    for (const [stage, undo] of [...frame].reverse()) {
      runtime.trace.push(['compensate', stage, 0n]);
      undo();
    }
  }
  return result;
}

function equalValues(a, b) {
  if (a === b) return true;
  if (a instanceof DataValue && b instanceof DataValue) {
    return a.tag === b.tag && a.fields.length === b.fields.length &&
      a.fields.every((field, i) => equalValues(field, b.fields[i]));
  }
  if (Array.isArray(a) && Array.isArray(b)) {
    return a.length === b.length && a.every((item, i) => equalValues(item, b[i]));
  }
  return false;
}

function attempts(runtime, policy, attempt) {
  const retry = policy.retry;
  let number = 1n, previous = 0n;
  for (;;) {
    runtime.trace.push(['start', policy.stage, number]);
    const result = scoped(runtime, policy, attempt);
    const failed = result instanceof DataValue && result.tag === 'Either::Left';
    runtime.trace.push(['finish', policy.stage, number, !failed]);
    if (!failed || retry === null) return result;
    if (retry.attempts > 0n && number >= retry.attempts) return result;
    let error = result.fields[0];
    if (policy.wraps) {
      // Only the step's own failures and timeouts are retried.
      if (error.tag === STAGE_FAILURE + 'StepFailed') error = error.fields[0];
      else if (error.tag !== STAGE_FAILURE + 'TimedOut') return result;
    }
    if (retry.when !== null && !retry.when(error)) return result;
    number += 1n;
    let delay;
    if (retry.strategy[0] === 'custom') {
      delay = retry.strategy[1](number, error, previous);
      if (delay === null) return result;
    } else {
      const base = retry.strategy[0] === 'immediate' ? 0n : retryDelay(retry.strategy, 2n);
      delay = jittered(retry.jitter, retryDelay(retry.strategy, number), previous, base, runtime.random);
    }
    runtime.trace.push(['sleep', policy.stage, delay]);
    runtime.clock.sleep(delay);
    previous = delay;
  }
}

/**
 * A synchronous attempt under its stage's timeout. On a virtual clock it
 * fails with TimedOut when more virtual time than the timeout passed while it
 * ran; a synchronous step cannot be interrupted, so on a real clock it runs
 * as it is. A hedge needs asynchronous steps (see hedged).
 */
function scoped(runtime, policy, attempt) {
  const timeout = policy.timeout !== null && policy.timeout > 0n;
  if (!timeout || !runtime.clock.virtual) return attempt();
  const began = runtime.clock.now();
  const result = attempt();
  if (runtime.clock.now() - began > policy.timeout) return stageFailure('TimedOut');
  return result;
}

/** A RetryDecision's delay in microseconds, or null to stop. */
export function retryDecision(decision) {
  if (decision.tag !== 'lawspec.time::type::RetryDecision::RetryAfter') return null;
  return decision.fields[0].fields[0];
}

// Asynchronous workflows: the same, with stages that await their steps. A
// stage's timeout and hedge are the Timeout and Hedge transformers of the
// Async ability, measured on the runtime's Clock. On a real clock a timeout
// races each attempt against a timer; on a virtual clock (generated tests,
// or a law using virtual clock) an attempt takes the virtual time that
// passes while it runs, so both are deterministic.

async function sleepFor(clock, delay) {
  await clock.sleepAsync(delay);
}

const TIMED_OUT = Symbol('timed out');

async function timed(runtime, policy, attempt, control) {
  if (policy.timeout === null || policy.timeout <= 0n) return attempt();
  if (runtime.clock.virtual) {
    const began = runtime.clock.now();
    const result = await attempt();
    if (runtime.clock.now() - began > policy.timeout) return stageFailure('TimedOut');
    return result;
  }
  if (!runtime.gates) return attempt();
  let timer;
  const expiry = new Promise((resolve) => {
    timer = setTimeout(() => resolve(TIMED_OUT), Number(policy.timeout) / 1000);
  });
  try {
    const result = await Promise.race([attempt(), expiry]);
    if (result !== TIMED_OUT) return result;
    control.stopped = true;
    return stageFailure('TimedOut');
  } finally {
    clearTimeout(timer);
  }
}

/**
 * A stage's hedge, [delay, most]: when an attempt has not succeeded after
 * delay, another starts beside it, up to most in all. The first success
 * wins; when every attempt fails, the last failure. On a virtual clock the
 * attempts run one after another (virtualHedge). On a real clock, off where
 * gates are.
 */
function hedged(runtime, policy, attempt, control) {
  if (policy.hedge === null) return attempt();
  if (runtime.clock.virtual) return virtualHedge(runtime, policy, attempt);
  if (!runtime.gates) return attempt();
  const [delay, most] = policy.hedge;
  return new Promise((resolve, reject) => {
    let started = 0n, pending = 0, timer;
    let finished = false;
    const finish = (settle, value) => {
      finished = true;
      clearTimeout(timer);
      settle(value);
    };
    const launch = () => {
      if (finished || control.stopped) return;
      started += 1n;
      pending += 1;
      if (started > 1n) runtime.trace.push(['hedge', policy.stage, started]);
      clearTimeout(timer);
      if (started < most) timer = setTimeout(launch, Number(delay) / 1000);
      Promise.resolve().then(attempt).then((result) => {
        pending -= 1;
        if (finished) return;
        if (!(result instanceof DataValue && result.tag === 'Either::Left')) finish(resolve, result);
        else if (pending === 0 && started >= most) finish(resolve, result);
        else if (pending === 0) launch();
      }, (error) => {
        if (!finished) finish(reject, error);
      });
    };
    launch();
  });
}

/**
 * A hedge on a virtual clock: attempts run one after another, and the next
 * starts when one fails, so the first success wins as it would in real time
 * when no attempt outlives the delay.
 */
async function virtualHedge(runtime, policy, attempt) {
  const most = BigInt(policy.hedge[1]);
  let started = 1n;
  let result = await attempt();
  while (result instanceof DataValue && result.tag === 'Either::Left' && started < most) {
    started += 1n;
    runtime.trace.push(['hedge', policy.stage, started]);
    result = await attempt();
  }
  return result;
}

async function attemptsAsync(runtime, policy, attempt) {
  const retry = policy.retry;
  let number = 1n, previous = 0n;
  for (;;) {
    runtime.trace.push(['start', policy.stage, number]);
    const control = {stopped: false};
    const result = await timed(runtime, policy, () => hedged(runtime, policy, attempt, control), control);
    const failed = result instanceof DataValue && result.tag === 'Either::Left';
    runtime.trace.push(['finish', policy.stage, number, !failed]);
    if (!failed || retry === null) return result;
    if (retry.attempts > 0n && number >= retry.attempts) return result;
    let error = result.fields[0];
    if (policy.wraps) {
      if (error.tag === STAGE_FAILURE + 'StepFailed') error = error.fields[0];
      else if (error.tag !== STAGE_FAILURE + 'TimedOut') return result;
    }
    if (retry.when !== null && !retry.when(error)) return result;
    number += 1n;
    let delay;
    if (retry.strategy[0] === 'custom') {
      delay = retry.strategy[1](number, error, previous);
      if (delay === null) return result;
    } else {
      const base = retry.strategy[0] === 'immediate' ? 0n : retryDelay(retry.strategy, 2n);
      delay = jittered(retry.jitter, retryDelay(retry.strategy, number), previous, base, runtime.random);
    }
    runtime.trace.push(['sleep', policy.stage, delay]);
    await sleepFor(runtime.clock, delay);
    previous = delay;
  }
}

/** runStage for an asynchronous stage: attempt() returns a promise. */
export async function runStageAsync(symbols, given, attempt, ...input) {
  const key = input[0];
  const policy = {key: given.stage, gates: [], cache: null, wraps: false, timeout: null, compensate: null, hedge: null, ...given};
  const runtime = workflowRuntime(symbols);
  const gates = runtime.gates ? policy.gates : [];
  let cached = null;
  if (policy.cache !== null && runtime.gates) {
    const cacheKey = policy.key + '/cache';
    if (!runtime.state.has(cacheKey)) runtime.state.set(cacheKey, []);
    cached = runtime.state.get(cacheKey);
    const now = runtime.clock.now();
    for (const [entry, value, expires] of cached) {
      if (now < expires && equalValues(entry, key)) {
        runtime.trace.push(['cached', policy.stage, 0n]);
        return value;
      }
    }
  }
  for (let i = 0; i < gates.length; i++) {
    const failure = passGate(runtime, policy, gates[i]);
    if (failure !== null) {
      for (const passed of gates.slice(0, i)) finishGate(runtime, policy, passed, false);
      return stageFailure(failure);
    }
  }
  const result = await attemptsAsync(runtime, policy, attempt);
  const succeeded = !(result instanceof DataValue && result.tag === 'Either::Left');
  for (const gate of gates) finishGate(runtime, policy, gate, succeeded);
  if (succeeded && policy.compensate !== null && runtime.frames.length > 0) {
    const value = result.fields[0];
    runtime.frames[runtime.frames.length - 1].push([policy.stage, () => policy.compensate(value)]);
  }
  if (cached !== null && succeeded) {
    const kept = cached.filter(([entry]) => !equalValues(entry, key));
    cached.length = 0;
    cached.push(...kept, [key, result, runtime.clock.now() + policy.cache]);
  }
  return result;
}

/**
 * The Async ability's default handler: the event loop. LawSpec code performs
 * pause; workflows reach the rest natively: spawn starts a function as a
 * task (a promise), wait gives a task's result, and all runs functions side
 * by side and gives their results in order. An `async` adapter is an adapter
 * that uses Async, so its promise is awaited as wait does.
 */
export class NativeAsync {
  /** A handler's operations run synchronously, so a pause returns at once. */
  pause() {}
  spawn(fn) {
    try {
      return Promise.resolve(fn());
    } catch (error) {
      return Promise.reject(error);
    }
  }
  wait(task) {
    return Promise.resolve(task);
  }
  /**
   * Every function's result, in order; all settle before the first error
   * (in order) is thrown.
   */
  async all(fns) {
    const outcomes = await Promise.allSettled(fns.map((fn) => this.spawn(fn)));
    const failed = outcomes.find((outcome) => outcome.status === 'rejected');
    if (failed) throw failed.reason;
    return outcomes.map((outcome) => outcome.value);
  }
}

export const ASYNC = new NativeAsync();

// An all group's step results, in declaration order. The steps run side by
// side as tasks of the Async ability's default handler; every step settles
// before a step's error (the first, in declaration order) is thrown.
export function concurrently(steps) {
  return ASYNC.all(steps);
}

/** runWorkflow for an asynchronous workflow; undos may be asynchronous. */

export async function runWorkflowAsync(symbols, attempt) {
  const runtime = workflowRuntime(symbols);
  const frame = [];
  runtime.frames.push(frame);
  let result;
  try {
    result = await attempt();
  } finally {
    runtime.frames.splice(runtime.frames.indexOf(frame), 1);
  }
  if (result instanceof DataValue && result.tag === 'Either::Left') {
    for (const [stage, undo] of [...frame].reverse()) {
      runtime.trace.push(['compensate', stage, 0n]);
      await undo();
    }
  }
  return result;
}


// Portable generation for stateful models. A type descriptor is an
// s-expression: (int T lo hi) with _ for no bound, (bool), (text), (unit),
// (list D), (maybe D), (either L R), (data NAME (ctor TAG D...) ...) and
// (ref NAME) for a data type declared in the model's table. Every target
// generates, shrinks and renders the same values for the same seed.

/** Parses s-expressions: lists, integers (bigint), strings, symbols and _ (null). */
export function readDescriptor(text) {
  let position = 0;
  const skip = () => {
    while (position < text.length && ' \t\r\n'.includes(text[position])) position++;
  };
  const item = () => {
    skip();
    const c = text[position];
    if (c === '(') {
      position++;
      const items = [];
      skip();
      while (text[position] !== ')') {
        items.push(item());
        skip();
      }
      position++;
      return items;
    }
    if (c === '"') {
      position++;
      let out = '';
      while (text[position] !== '"') {
        if (text[position] === '\\') position++;
        out += text[position];
        position++;
      }
      position++;
      return out;
    }
    const start = position;
    while (position < text.length && !' \t\r\n()'.includes(text[position])) position++;
    const atom = text.slice(start, position);
    if (atom === '_') return null;
    if (/^-*[0-9]+$/.test(atom)) return BigInt(atom);
    return atom;
  };
  const items = [];
  skip();
  while (position < text.length) {
    items.push(item());
    skip();
  }
  return items;
}

const UNBOUNDED = 1000000n;
const bigMin = (a, b) => (a < b ? a : b);
const bigMax = (a, b) => (a > b ? a : b);
const isRef = (fd, name) =>
  Array.isArray(fd) && fd.length === 2 && fd[0] === 'ref' && fd[1] === name;

function mentionsData(d) {
  return Array.isArray(d) &&
    (d[0] === 'ref' || d[0] === 'data' || d.slice(1).some(mentionsData));
}

/** Generation, shrinking and rendering over a table of data types. */
export class Values {
  table;
  constructor(table) { this.table = table; }
  resolve(d) { return d[0] === 'ref' ? this.table.get(d[1]) : d; }
  /**
   * An integer's range: a missing bound is 1,000,000 from zero, or
   * 2,000,000 from the other bound when that is beyond it.
   */
  bounds(d) {
    const lo = d[2], hi = d[3];
    if (lo === null && hi === null) return [-UNBOUNDED, UNBOUNDED];
    if (lo === null) return [bigMin(-UNBOUNDED, hi - 2n * UNBOUNDED), hi];
    if (hi === null) return [lo, bigMax(UNBOUNDED, lo + 2n * UNBOUNDED)];
    return [lo, hi];
  }
  /** The constructors whose fields mention no data type. */
  base(d) {
    const found = d.slice(2).filter((c) => !c.slice(2).some(mentionsData));
    return found.length ? found : d.slice(2);
  }
  generate(d, random, size) {
    d = this.resolve(d);
    const n = BigInt(size);
    switch (d[0]) {
      case 'int': {
        const [lo, hi] = this.bounds(d);
        if (random.below(10n) < 2n) {
          const specials = [lo, hi, bigMin(bigMax(0n, lo), hi), bigMin(bigMax(1n, lo), hi)];
          return specials[Number(random.below(4n))];
        }
        return lo + random.below(hi - lo + 1n);
      }
      case 'bool':
        return random.below(2n) === 1n;
      case 'text': {
        let out = '';
        for (let i = random.below(n + 1n); i > 0n; i--)
          out += String.fromCharCode(32 + Number(random.below(95n)));
        return out;
      }
      case 'unit':
        return UNIT;
      case 'list': {
        const out = [];
        for (let i = random.below(n + 1n); i > 0n; i--) out.push(this.generate(d[1], random, n));
        return out;
      }
      case 'maybe':
        if (random.below(4n) === 0n) return new DataValue('Maybe::Nothing', []);
        return new DataValue('Maybe::Just', [this.generate(d[1], random, n)]);
      case 'either':
        if (random.below(2n) === 0n) return new DataValue('Either::Left', [this.generate(d[1], random, n)]);
        return new DataValue('Either::Right', [this.generate(d[2], random, n)]);
      case 'data': {
        const choices = n <= 0n ? this.base(d) : d.slice(2);
        const ctor = choices[Number(random.below(BigInt(choices.length)))];
        const smaller = bigMax(n - 1n, 0n);
        return new DataValue(String(ctor[1]), ctor.slice(2).map((f) => this.generate(f, random, smaller)));
      }
    }
    throw new TypeError('unknown descriptor ' + render(d));
  }
  minimal(d) {
    d = this.resolve(d);
    switch (d[0]) {
      case 'int': {
        const [lo, hi] = this.bounds(d);
        return bigMin(bigMax(0n, lo), hi);
      }
      case 'bool': return false;
      case 'text': return '';
      case 'unit': return UNIT;
      case 'list': return [];
      case 'maybe': return new DataValue('Maybe::Nothing', []);
      case 'either': return new DataValue('Either::Left', [this.minimal(d[1])]);
    }
    const ctor = this.base(d)[0];
    return new DataValue(String(ctor[1]), ctor.slice(2).map((f) => this.minimal(f)));
  }
  /** Smaller candidates for v, most aggressive first. */
  shrink(d, v) {
    d = this.resolve(d);
    let out = [];
    // Removals and halvings of a sequence, as arrays of its elements.
    const smaller = (items) => [
      [], items.slice(0, Math.floor(items.length / 2)),
      ...items.map((_, i) => [...items.slice(0, i), ...items.slice(i + 1)]),
    ];
    switch (d[0]) {
      case 'int': {
        const target = this.minimal(d);
        // bigint division truncates toward zero.
        if (v !== target) out = [target, v - (v - target) / 2n, v - (v > target ? 1n : -1n)];
        break;
      }
      case 'bool':
        out = v ? [false] : [];
        break;
      case 'text':
        if (v) out = smaller([...v]).map((cs) => cs.join(''));
        break;
      case 'list':
        if (v.length) {
          out = smaller(v);
          v.forEach((item, i) => {
            for (const c of this.shrink(d[1], item)) out.push([...v.slice(0, i), c, ...v.slice(i + 1)]);
          });
        }
        break;
      case 'maybe':
        if (v.tag === 'Maybe::Just')
          out = [new DataValue('Maybe::Nothing', []),
            ...this.shrink(d[1], v.fields[0]).map((c) => new DataValue('Maybe::Just', [c]))];
        break;
      case 'either': {
        const inner = v.tag === 'Either::Left' ? d[1] : d[2];
        out = this.shrink(inner, v.fields[0]).map((c) => new DataValue(v.tag, [c]));
        break;
      }
      case 'data': {
        const fields = d.slice(2).find((c) => String(c[1]) === v.tag).slice(2);
        out = [this.minimal(d)];
        // A field of the same type is a smaller value of it.
        v.fields.forEach((f, i) => { if (i < fields.length && isRef(fields[i], d[1])) out.push(f); });
        v.fields.forEach((field, i) => {
          if (i >= fields.length) return;
          for (const c of this.shrink(fields[i], field))
            out.push(new DataValue(v.tag, [...v.fields.slice(0, i), c, ...v.fields.slice(i + 1)]));
        });
        break;
      }
    }
    const seen = new Set([render(v)]);
    return out.filter((c) => {
      const text = render(c);
      if (seen.has(text)) return false;
      seen.add(text);
      return true;
    });
  }
}

/** A value's canonical text, the same on every target. */
export function render(v) {
  if (isHandle(v)) return handleTable(v).get(v);
  if (typeof v === 'boolean') return v ? 'true' : 'false';
  if (typeof v === 'bigint' || typeof v === 'number') return String(v);
  if (typeof v === 'string') return '"' + v.replace(/\\/g, '\\\\').replace(/"/g, '\\"') + '"';
  if (v === UNIT) return '()';
  if (Array.isArray(v)) return '[' + v.map(render).join(', ') + ']';
  if (v instanceof DataValue) {
    const name = v.tag.split('::').pop();
    return v.fields.length ? name + '(' + v.fields.map(render).join(', ') + ')' : name;
  }
  return String(v);
}

/** A descriptor text's data types and its last form, the one generated. */
export function valuesFrom(text) {
  const forms = readDescriptor(text);
  const table = new Map(
      forms.filter((f) => Array.isArray(f) && f[0] === 'data').map((f) => [String(f[1]), f]));
  return [new Values(table), forms[forms.length - 1]];
}

/** count values generated from one SplitMix64 seed, rendered. */
export function generated(text, seed, size, count) {
  const [values, d] = valuesFrom(text);
  const random = new SplitMix64(BigInt(seed));
  return Array.from({length: Number(count)}, () => render(values.generate(d, random, size)));
}

/** The shrink candidates of the first value generated, rendered. */
export function shrunk(text, seed, size) {
  const [values, d] = valuesFrom(text);
  return values.shrink(d, values.generate(d, new SplitMix64(BigInt(seed)), size)).map(render);
}

// Stateful models. A model's spec (see LawSpec.MachineSpec) lists its data
// types, start and commands; the callbacks beside it are the generated
// definitions that call the adapters, the references over the model state,
// preconditions, the abstraction and invariants, each taking symbols first
// and each awaited. A run is generated by simulating the pure model, so
// every command in it is allowed by typestate, its precondition and its
// reference; it is then executed against the adapters and every result,
// abstracted state and invariant is checked. A failing run is shrunk by
// dropping commands and shrinking arguments, replaying the model to keep
// each candidate valid.

const fieldsOf = (forms) => new Map(forms.map((f) => [f[0], f.slice(1)]));

// Actors. An actor owns a state and handles one message at a time, in the
// order they arrive: each message runs after the previous one settles, on a
// promise chain, so an idle actor costs only its state.

/** A message sent to an actor or mailbox that has stopped. */
export class ActorStopped extends Error {
  constructor(message) {
    super(message);
    this.name = 'ActorStopped';
  }
}

/**
 * A handler failed, so the actor crashed; cause is what the handler threw.
 * A supervised actor restarts; any other stops.
 */
export class ActorCrashed extends Error {
  constructor(cause) {
    super(`the actor crashed: ${cause instanceof Error ? cause.message : String(cause)}`);
    this.name = 'ActorCrashed';
    this.cause = cause;
  }
}

/** A message that crashes the actor on purpose (crash, links). */
class RestartSignal {
  constructor(cause, origin) {
    this.cause = cause;
    this.origin = origin;
  }
}

let crashIds = 0;
const nextCrash = () => ++crashIds;

/**
 * An actor: a state, a mailbox, and one message handled at a time. Each
 * message runs after the previous one settles, on a promise chain, so an
 * idle actor costs only its state. options.restart(last state) gives the
 * state after a crash; without it, a crash stops the actor even under a
 * supervisor. A supervised actor restarts in place: it keeps its address and
 * the messages waiting for it.
 */
export class Actor {
  #state;
  #restartState;
  #tail = Promise.resolve();
  #pending = 0;
  #stopped = false;
  #halted = false;
  #monitors = [];
  #links = [];
  #seen = new Set();
  _supervisor = null;
  constructor(state, options = {}) {
    this.#state = state;
    this.#restartState = options.restart ?? null;
  }
  get _restartable() {
    return this.#restartState !== null;
  }
  #post(handler) {
    if (this.#stopped || this.#halted) throw new ActorStopped('the actor has stopped');
    this.#pending += 1;
    const reply = this.#tail.then(async () => {
      try {
        if (this.#halted) throw new ActorStopped('the actor has stopped');
        let out;
        try {
          out = await handler(this.#state);
        } catch (error) {
          if (error instanceof RestartSignal) {
            await this.#crashed(error.cause, error.origin);
            return undefined;
          }
          await this.#crashed(error, nextCrash());
          throw new ActorCrashed(error);
        }
        this.#state = out[1];
        return out[0];
      } finally {
        this.#pending -= 1;
      }
    });
    this.#tail = reply.catch(() => {});
    return reply;
  }
  /**
   * On the actor's turn: restart or stop, then tell monitors and links.
   * origin names the first crash, so a crash crosses each link once. With a
   * synchronous restart function it completes synchronously.
   */
  async #crashed(cause, origin) {
    this.#seen.add(origin);
    const restarted = this._supervisor !== null && this.#restartState !== null &&
      this._supervisor._childCrashed(this, cause);
    if (restarted) {
      const pending = this._restartNow();
      if (pending !== undefined) await pending;
    } else {
      this._halt();
    }
    for (const monitor of [...this.#monitors]) monitor(['crashed', cause]);
    for (const other of [...this.#links]) other._linkCrash(cause, origin);
  }
  /** On the actor's turn: the restarted state from the last one. */
  _restartNow() {
    const next = this.#restartState(this.#state);
    if (next instanceof Promise) return next.then((s) => { this.#state = s; });
    this.#state = next;
    return undefined;
  }
  /** A restart a supervisor asks of a sibling, in mailbox order. */
  _restartLater() {
    try {
      this.#post(async (s) => [undefined, await this.#restartState(s)]).catch(() => {});
    } catch (error) {
      if (!(error instanceof ActorStopped)) throw error;
    }
  }
  _linkCrash(cause, origin) {
    if (this.#seen.has(origin)) return;
    try {
      // Checked again on its turn: the same crash may arrive by two links.
      this.#post((s) => {
        if (this.#seen.has(origin)) return [undefined, s];
        throw new RestartSignal(cause, origin);
      }).catch(() => {});
    } catch (error) {
      if (!(error instanceof ActorStopped)) throw error;
    }
  }
  /** Stops the actor; messages still waiting fail with ActorStopped. */
  _halt() {
    this.#stopped = true;
    this.#halted = true;
  }
  /**
   * Synchronous code's fast path: runs a synchronous handler at once and
   * returns its result. The actor must be idle, with no message waiting;
   * otherwise this throws, and the caller should await call instead. A
   * handler that throws crashes the actor, as with call.
   */
  callNow(handler) {
    if (this.#stopped || this.#halted) throw new ActorStopped('the actor has stopped');
    if (this.#pending > 0) throw new Error('the actor has messages waiting; await the call instead');
    let out;
    try {
      out = handler(this.#state);
    } catch (error) {
      if (error instanceof RestartSignal) {
        this.#crashed(error.cause, error.origin);
        return undefined;
      }
      this.#crashed(error, nextCrash());
      throw new ActorCrashed(error);
    }
    this.#state = out[1];
    return out[0];
  }
  /**
   * Runs handler(state) -> [result, next state] (or a promise of it) in turn;
   * resolves to the result. A handler that throws crashes the actor, and the
   * call rejects with ActorCrashed.
   */
  call(handler) {
    try {
      return this.#post(handler);
    } catch (error) {
      return Promise.reject(error);
    }
  }
  /** Queues handler(state) -> [result, next state] without waiting. */
  cast(handler) {
    this.#post(handler).catch(() => {});
  }
  /**
   * Crashes the actor once the messages before this one are handled, as a
   * failing handler would: for testing supervision.
   */
  crash(cause = 'crashed on purpose') {
    const origin = nextCrash();
    return this.call(() => { throw new RestartSignal(cause, origin); });
  }
  /** crash for synchronous code: the actor must have no messages waiting. */
  crashNow(cause = 'crashed on purpose') {
    const origin = nextCrash();
    this.callNow(() => { throw new RestartSignal(cause, origin); });
  }
  /**
   * Replaces the state by restart(last state) between messages, as a
   * supervised restart does (crash injection in model runs).
   */
  restart(restart) {
    return this.call(async (s) => [undefined, await restart(s)]);
  }
  /** The state after every message sent before this call. */
  state() {
    return this.call((s) => [s, s]);
  }
  /** notify(['crashed', cause]) after each crash, and notify(['stopped', null]) once it stops. */
  monitor(notify) {
    this.#monitors.push(notify);
  }
  /** Links two actors: when either crashes, the other crashes too. */
  link(other) {
    this.#links.push(other);
    other.#links.push(this);
  }
  /**
   * Refuses further messages; those already queued still run. A permanent
   * child of a supervisor restarts instead.
   */
  stop() {
    if (this._supervisor !== null && this._supervisor._childStopped(this)) return;
    const already = this.#stopped;
    this.#stopped = true;
    if (!already) for (const monitor of [...this.#monitors]) monitor(['stopped', null]);
  }
}

const STRATEGIES = ['one_for_one', 'one_for_all', 'rest_for_one'];
const LIFETIMES = ['permanent', 'transient', 'temporary'];

/**
 * Starts children (actors or supervisors) and restarts them after a crash.
 * strategy 'one_for_one' restarts the child that crashed, 'one_for_all'
 * every child, 'rest_for_one' it and those added after it. A child's
 * lifetime: 'permanent' restarts after a crash or a stop, 'transient' only
 * after a crash, 'temporary' never. More than maxRestarts within period
 * seconds is the supervisor's own crash: its supervisor restarts all of its
 * children, or, at the top, every child stops.
 */
export class Supervisor {
  _supervisor = null;
  #children = [];
  #restarts = [];
  #stopped = false;
  #monitors = [];
  constructor(strategy = 'one_for_one', maxRestarts = 3, period = 5) {
    if (!STRATEGIES.includes(strategy)) throw new Error(`unknown strategy ${strategy}`);
    this.strategy = strategy;
    this.maxRestarts = maxRestarts;
    this.period = period;
  }
  /** Adds a started child, and returns it. */
  supervise(child, lifetime = 'permanent') {
    if (!LIFETIMES.includes(lifetime)) throw new Error(`unknown lifetime ${lifetime}`);
    child._supervisor = this;
    this.#children.push([child, lifetime]);
    return child;
  }
  children() {
    return this.#children.map(([c]) => c);
  }
  get _restartCount() {
    return this.#restarts.length;
  }
  #allowRestart() {
    const now = (globalThis.performance?.now?.() ?? Date.now()) / 1000;
    while (this.#restarts.length && now - this.#restarts[0] > this.period) this.#restarts.shift();
    if (this.#restarts.length >= this.maxRestarts) return false;
    this.#restarts.push(now);
    return true;
  }
  #entry(child) {
    return this.#children.find((e) => e[0] === child);
  }
  /** The children to restart for entry's crash, or null when it gives up. */
  #restarting(entry, cause, crashed) {
    if (this.#allowRestart()) {
      const index = this.#children.indexOf(entry);
      if (this.strategy === 'one_for_one') return [entry];
      if (this.strategy === 'one_for_all') return [...this.#children];
      return this.#children.slice(index);
    }
    const parent = this._supervisor;
    if (parent !== null && parent._childFailed(this, cause)) {
      this.#restarts = [];
      return [...this.#children];
    }
    this.#fail(crashed, cause);
    return null;
  }
  #removeTemporary(entry) {
    if (entry[1] !== 'temporary') return false;
    this.#children.splice(this.#children.indexOf(entry), 1);
    return true;
  }
  /** On child's turn: true when it restarts now. */
  _childCrashed(child, cause) {
    const entry = this.#entry(child);
    if (this.#stopped || entry === undefined || this.#removeTemporary(entry)) return false;
    const group = this.#restarting(entry, cause, child);
    if (group === null) return false;
    for (const [other] of group) if (other !== child) other._restartLater();
    return true;
  }
  /** A child supervisor gave up: true when it may restart its children. */
  _childFailed(child, cause) {
    const entry = this.#entry(child);
    if (this.#stopped || entry === undefined || this.#removeTemporary(entry)) return false;
    const group = this.#restarting(entry, cause, child);
    if (group === null) return false;
    for (const [other] of group) if (other !== child) other._restartLater();
    return true;
  }
  /** True when a stopped child is permanent and restarts instead. */
  _childStopped(child) {
    const entry = this.#entry(child);
    if (entry === undefined || this.#stopped) return false;
    if (entry[1] !== 'permanent') {
      this.#children.splice(this.#children.indexOf(entry), 1);
      return false;
    }
    const group = this.#restarting(entry, 'stopped', child);
    if (group === null) return false;
    for (const [other] of group) other._restartLater();
    return true;
  }
  /** Every child but the one crashing (which stops itself) stops, and so does the supervisor. */
  #fail(crashed, cause) {
    const children = this.#children;
    this.#children = [];
    this.#stopped = true;
    for (const [other] of [...children].reverse()) {
      other._supervisor = null;
      if (other !== crashed) other._halt();
    }
    for (const monitor of [...this.#monitors]) monitor(['crashed', cause]);
  }
  /** Restarted by its own supervisor: every child restarts. */
  _restartLater() {
    this.#restarts = [];
    for (const [child] of [...this.#children]) child._restartLater();
  }
  _halt() {
    this.stop();
  }
  /** notify(['crashed', cause]) when it gives up, and notify(['stopped', null]) once stopped. */
  monitor(notify) {
    this.#monitors.push(notify);
  }
  /** Stops every child, last added first, without restarting them. */
  stop() {
    if (this.#stopped) return;
    this.#stopped = true;
    const children = this.#children;
    this.#children = [];
    for (const [child] of [...children].reverse()) {
      child._supervisor = null;
      child.stop();
    }
    for (const monitor of [...this.#monitors]) monitor(['stopped', null]);
  }
}

/**
 * The runtime's own check of crashes, links, monitors and supervision:
 * every strategy, lifetime, the restart limit and escalation. Rejects with
 * an Error naming the first behaviour that differs.
 */
export async function checkSupervisionAsync() {
  const pause = () => new Promise((resolve) => setTimeout(resolve, 10));
  const counter = () => new Actor(0, {restart: () => 0});
  const bump = (a) => a.call((s) => [s + 1, s + 1]);
  const fail = async (a) => {
    try {
      await a.call(() => { throw new Error('division by zero'); });
    } catch (error) {
      if (error instanceof ActorCrashed) return;
      throw error;
    }
    throw new Error('a failing handler did not reject with ActorCrashed');
  };
  const stopped = async (a, what) => {
    try {
      await a.state();
    } catch (error) {
      if (error instanceof ActorStopped) return;
      throw error;
    }
    throw new Error(`${what} should have stopped`);
  };
  const expect = (actual, wanted, what) => {
    if (JSON.stringify(actual) !== JSON.stringify(wanted))
      throw new Error(`${what}: got ${JSON.stringify(actual)}, expected ${JSON.stringify(wanted)}`);
  };
  const states = (...actors) => Promise.all(actors.map((a) => a.state()));

  let a = counter();
  await bump(a);
  await fail(a);
  await stopped(a, 'an unsupervised actor that crashed');
  let sup = new Supervisor('one_for_one');
  let x = sup.supervise(counter()), y = sup.supervise(counter());
  await bump(x); await bump(y); await bump(y);
  await fail(x);
  expect(await states(x, y), [0, 2], 'one for one restarts only the crashed child');
  sup = new Supervisor('one_for_all');
  x = sup.supervise(counter()); y = sup.supervise(counter());
  await bump(x); await bump(y);
  await fail(x);
  expect(await states(x, y), [0, 0], 'one for all restarts every child');
  sup = new Supervisor('rest_for_one');
  let z;
  [x, y, z] = [sup.supervise(counter()), sup.supervise(counter()), sup.supervise(counter())];
  await bump(x); await bump(y); await bump(z);
  await fail(y);
  expect(await states(x, y, z), [1, 0, 0], 'rest for one restarts the child and later ones');
  sup = new Supervisor();
  const t = sup.supervise(counter(), 'temporary');
  await fail(t);
  await stopped(t, 'a temporary child that crashed');
  sup = new Supervisor();
  const p = sup.supervise(counter(), 'permanent'), q = sup.supervise(counter(), 'transient');
  await bump(p);
  p.stop();
  expect(await p.state(), 0, 'a permanent child restarts after a stop');
  q.stop();
  await stopped(q, 'a transient child that was stopped');
  const events = [];
  sup = new Supervisor('one_for_one', 2, 10);
  sup.monitor((e) => events.push(e));
  x = sup.supervise(counter()); y = sup.supervise(counter());
  await fail(x); await fail(x); await fail(x);
  await stopped(y, 'a child of a supervisor past its restart limit');
  expect(events.map((e) => e[0]), ['crashed'], 'a supervisor past its limit tells its monitors');
  const outer = new Supervisor('one_for_one', 5, 10);
  const inner = outer.supervise(new Supervisor('one_for_one', 1, 10));
  x = inner.supervise(counter()); y = inner.supervise(counter());
  await bump(y);
  await fail(x); await fail(x);
  expect(await states(x, y), [0, 0], 'a supervisor past its limit is restarted by its own');
  const seen = [];
  a = counter();
  let b = counter();
  a.link(b);
  b.monitor((e) => seen.push(e));
  await fail(a);
  for (let i = 0; i < 100 && !seen.length; i++) await pause();
  await stopped(b, 'an unsupervised actor linked to one that crashed');
  expect(seen.map((e) => e[0]), ['crashed'], 'a monitor hears of a crash');
  sup = new Supervisor('one_for_one', 10);
  let c;
  [a, b, c] = [sup.supervise(counter()), sup.supervise(counter()), sup.supervise(counter())];
  a.link(b); b.link(c); c.link(a);
  await bump(a); await bump(b); await bump(c);
  await fail(a);
  for (let i = 0; i < 100 && sup._restartCount < 3; i++) await pause();
  await pause();
  expect([...(await states(a, b, c)), sup._restartCount], [0, 0, 0, 3], 'a crash crosses each link once');
}

/**
 * A queue with many senders and one receiver: the channel form of an actor.
 * A process that loops over receiveAsync() and answers each message is an
 * actor written by hand; send() never waits.
 */
export class Mailbox {
  #items = [];
  #waiters = [];
  #closed = false;
  send(value) {
    if (this.#closed) throw new ActorStopped('the mailbox is closed');
    const waiter = this.#waiters.shift();
    if (waiter) waiter.resolve(value);
    else this.#items.push(value);
  }
  /**
   * The next message; waits up to timeoutMs (forever when omitted) and
   * rejects with a timeout error, or ActorStopped once closed and empty.
   */
  receiveAsync(timeoutMs) {
    if (this.#items.length > 0) return Promise.resolve(this.#items.shift());
    if (this.#closed) return Promise.reject(new ActorStopped('the mailbox is closed'));
    return new Promise((resolve, reject) => {
      const waiter = {resolve, reject};
      if (timeoutMs !== undefined) {
        const timer = setTimeout(() => {
          const at = this.#waiters.indexOf(waiter);
          if (at >= 0) this.#waiters.splice(at, 1);
          reject(new Error('no message arrived in time'));
        }, timeoutMs);
        waiter.resolve = (value) => { clearTimeout(timer); resolve(value); };
        waiter.reject = (error) => { clearTimeout(timer); reject(error); };
      }
      this.#waiters.push(waiter);
    });
  }
  /**
   * The Mailbox ability's receive ... within d: resolves to the next
   * message, or null when none arrives within micros microseconds. On a
   * virtual clock (a Clock handler that is not real time) it waits no real
   * time: it takes a message already sent, or lets the time pass on that
   * clock and gives null. Rejects with ActorStopped once closed and empty.
   */
  async receiveWithin(micros, clock = null) {
    if (clock !== null && clock !== undefined && !realTimeClock(clock)) {
      if (this.#items.length > 0) return this.#items.shift();
      if (this.#closed) throw new ActorStopped('the mailbox is closed');
      await loadDurationClass();
      clock.sleep(nativeDuration(micros));
      return null;
    }
    const wait = Math.max(0, Number(micros) / 1000);
    try {
      return await this.receiveAsync(wait);
    } catch (error) {
      if (error instanceof ActorStopped) throw error;
      return null;
    }
  }
  /** Refuses further messages; those already sent can still be received. */
  close() {
    this.#closed = true;
    for (const waiter of this.#waiters.splice(0)) waiter.reject(new ActorStopped('the mailbox is closed'));
  }
}

/**
 * A handler bridge (state first, returning Pair result state, or the state
 * alone for a Unit result) as a command on an actor.
 */
function actorCommand(run, unit) {
  if (unit) return (symbols, actor, ...args) => actor.call(async (s) => [UNIT, await run(symbols, s, ...args)]);
  return (symbols, actor, ...args) => actor.call(async (s) => {
    const out = await run(symbols, s, ...args);
    return [out.fields[0], out.fields[1]];
  });
}

class ModelCommand {
  name;
  arguments;
  state;
  unit;
  needs;
  shifts;
  key;
  run;
  reference;
  when;
  constructor(form, callbacks) {
    const fields = fieldsOf(form.slice(2));
    this.name = String(form[1]);
    this.arguments = fields.get('arguments');
    this.state = Number(fields.get('state')[0]);
    this.unit = fields.get('unit')[0] === 'true';
    this.needs = fields.get('needs');
    this.shifts = fields.get('shifts');
    // The argument naming the key the command touches, for per-key checks.
    const key = (fields.get('key') ?? ['none'])[0];
    this.key = key === 'none' ? null : Number(key);
    this.restart = (fields.get('restart') ?? ['false'])[0] === 'true';
    [this.run, this.reference, this.when] = callbacks;
  }
  admits(indices) {
    const n = Math.min(this.needs.length, indices.length);
    for (let k = 0; k < n; k++) {
      const [kind, bound] = this.needs[k], i = indices[k];
      if (kind === 'atleast' ? !(i >= bound) : i !== bound) return false;
    }
    return true;
  }
  shifted(indices) {
    const n = Math.min(this.shifts.length, indices.length);
    return Array.from({length: n}, (_, k) => {
      const [kind, by] = this.shifts[k];
      return kind === 'by' ? indices[k] + by : by;
    });
  }
}

export class Model {
  name;
  shared;
  values;
  startIndices;
  startArguments;
  startRun;
  startModel;
  commands;
  abstract;
  invariants;
  perKey;
  constructor(spec, start, commands, abstract = null, invariants = []) {
    const forms = readDescriptor(spec).filter(Array.isArray);
    this.name = String(forms[0][1]);
    this.shared = forms[0][2] === 'shared';
    this.values = new Values(new Map(forms.filter((f) => f[0] === 'data').map((f) => [String(f[1]), f])));
    const startFields = fieldsOf(forms.find((f) => f[0] === 'start').slice(1));
    this.startIndices = startFields.get('indices') ?? [];
    this.startArguments = startFields.get('arguments') ?? [];
    [this.startRun, this.startModel] = start;
    const commandForms = forms.filter((f) => f[0] === 'command');
    const n = Math.min(commandForms.length, commands.length);
    this.commands = Array.from({length: n}, (_, i) => new ModelCommand(commandForms[i], commands[i]));
    this.abstract = abstract ?? null;
    const kinds = forms.find((f) => f[0] === 'invariants').slice(1);
    this.invariants = kinds.slice(0, invariants.length).map((k, i) => [k, invariants[i]]);
    this.perKey = forms.some((f) => f[0] === 'perkey' && f[1] === 'true');
    this.consistency = String(forms.find((f) => f[0] === 'consistency')?.[1] ?? 'linearizable');
    // Sequential runs of an actor also inject crashes: the actor restarts
    // from its last state (restart from) or its start, and the model follows
    // the restart's reference (or the start's model state).
    const restarts = this.commands.filter((c) => c.restart);
    this.commands = this.commands.filter((c) => !c.restart);
    this.steps = this.commands;
    // An actor model's start and handlers run inside an actor; the
    // abstraction and state invariants read its state between messages.
    if (forms.some((f) => f[0] === 'actor' && f[1] === 'true')) {
      const run = this.startRun, begin = this.startModel;
      this.startRun = async (symbols, ...args) => {
        symbols.set('_lawspec_start', args);
        return new Actor(await run(symbols, ...args));
      };
      this.startModel = async (symbols, ...args) => {
        symbols.set('_lawspec_start', args);
        return begin(symbols, ...args);
      };
      for (const c of this.commands) c.run = actorCommand(c.run, c.unit);
      this.steps = [...this.commands, new Crash(run, begin, restarts[0] ?? null)];
      if (abstract != null) this.abstract = async (symbols, actor) => abstract(symbols, await actor.state());
      this.invariants = this.invariants.map(([k, p]) =>
        [k, k === 'state' ? async (symbols, actor) => p(symbols, await actor.state()) : p]);
    }
  }
}

/** An injected crash of an actor model, as a step with no arguments. */
class Crash {
  name = 'crash';
  arguments = [];
  state = 0;
  unit = true;
  when = null;
  key = null;
  restart = false;
  #startRun;
  #startModel;
  #restart;
  constructor(startRun, startModel, restart) {
    this.#startRun = startRun;
    this.#startModel = startModel;
    this.#restart = restart;
  }
  admits() {
    return true;
  }
  shifted(indices) {
    return indices;
  }
  async run(symbols, actor) {
    if (this.#restart !== null) await actor.restart((s) => this.#restart.run(symbols, s));
    else await actor.restart(() => this.#startRun(symbols, ...symbols.get('_lawspec_start')));
    return UNIT;
  }
  reference(symbols, state) {
    if (this.#restart !== null) return this.#restart.reference(symbols, state);
    return this.#startModel(symbols, ...symbols.get('_lawspec_start'));
  }
}

/** A command the model does not allow here. */
class Invalid extends Error {}

/** The model states along a run, or throws Invalid. */
async function simulate(model, symbols, run) {
  const [startArgs, steps] = run;
  let state;
  try {
    state = await model.startModel(symbols, ...startArgs);
  } catch {
    throw new Invalid();
  }
  let indices = [...model.startIndices];
  const states = [state];
  for (const [index, args] of steps) {
    const command = model.steps[index];
    if (!command.admits(indices)) throw new Invalid();
    [state] = await stepModel(command, symbols, args, state);
    indices = command.shifted(indices);
    states.push(state);
  }
  return states;
}

/** The next model state and the result the model returns. */
async function stepModel(command, symbols, args, state) {
  let out;
  try {
    if (command.when !== null && command.when !== undefined && !(await command.when(symbols, state)))
      throw new Invalid();
    out = await command.reference(symbols, ...args, state);
  } catch {
    throw new Invalid();
  }
  if (command.unit) return [out, UNIT];
  return [out.fields[1], out.fields[0]];
}

async function generateRun(model, random, length, size, crashes = false) {
  const symbols = new Map();
  const startArgs = model.startArguments.map((d) => model.values.generate(d, random, size));
  let state;
  try {
    state = await model.startModel(symbols, ...startArgs);
  } catch {
    return [startArgs, []];
  }
  let indices = [...model.startIndices];
  const steps = [];
  for (let n = 0; n < length; n++) {
    const allowed = [];
    model.commands.forEach((c, i) => { if (c.admits(indices)) allowed.push(i); });
    if (!allowed.length) break;
    let index = allowed[Number(random.below(BigInt(allowed.length)))];
    // One step in eight of an actor's run is a crash.
    if (crashes && model.steps.length > model.commands.length && random.below(8n) === 0n)
      index = model.commands.length;
    const command = model.steps[index];
    const args = command.arguments.map((d) => model.values.generate(d, random, size));
    try {
      [state] = await stepModel(command, symbols, args, state);
    } catch (error) {
      if (error instanceof Invalid) continue;
      throw error;
    }
    steps.push([index, args]);
    indices = command.shifted(indices);
  }
  return [startArgs, steps];
}

const errorName = (error) =>
  (error !== null && typeof error === 'object' && (error.name || error.constructor?.name)) || typeof error;
const errorMessage = (error) =>
  error instanceof Error ? error.message : String(error);

/**
 * null when the system agrees with the model along the run; otherwise the
 * failing step's number and what went wrong.
 */
async function execute(model, run) {
  const [startArgs, steps] = run;
  const symbols = new Map();
  let step = 0;
  try {
    let state = await model.startRun(symbols, ...startArgs);
    let expected = await model.startModel(symbols, ...startArgs);
    let failure = await checkState(model, symbols, state, expected);
    if (failure) return [step, failure];
    for (const [index, args] of steps) {
      step += 1;
      const command = model.steps[index];
      const full = [...args];
      full.splice(command.state, 0, state);
      const out = await command.run(symbols, ...full);
      let result;
      if (model.shared) {
        result = out;
      } else {
        result = command.unit ? UNIT : out.fields[0];
        state = out.fields[out.fields.length - 1];
      }
      let wanted;
      [expected, wanted] = await stepModel(command, symbols, args, expected);
      if (!command.unit && compareValues(result, wanted) !== 0)
        return [step, `returned ${render(result)}; the model returns ${render(wanted)}`];
      failure = await checkState(model, symbols, state, expected);
      if (failure) return [step, failure];
    }
  } catch (error) {
    if (error instanceof Invalid) return [step, 'the model does not allow this step'];
    return [step, `raised ${errorName(error)}: ${errorMessage(error)}`];
  }
  return null;
}

async function checkState(model, symbols, state, expected) {
  if (model.abstract !== null) {
    const actual = await model.abstract(symbols, state);
    if (compareValues(actual, expected) !== 0)
      return `the state is ${render(actual)}; the model is ${render(expected)}`;
  }
  for (const [kind, invariant] of model.invariants)
    if (!(await invariant(symbols, kind === 'model' ? expected : state)))
      return `an invariant on the ${kind} fails`;
  return null;
}

function* shrinkCandidates(model, run) {
  const [startArgs, steps] = run;
  const n = steps.length;
  for (let size = Math.floor(n / 2); size >= 1; size = Math.floor(size / 2))
    for (let begin = 0; begin < n; begin += size)
      yield [startArgs, [...steps.slice(0, begin), ...steps.slice(begin + size)]];
  for (let k = 0; k < n; k++) {
    const [index, args] = steps[k];
    const command = model.steps[index];
    const m = Math.min(command.arguments.length, args.length);
    for (let j = 0; j < m; j++)
      for (const c of model.values.shrink(command.arguments[j], args[j]))
        yield [startArgs, [...steps.slice(0, k), [index, [...args.slice(0, j), c, ...args.slice(j + 1)]],
          ...steps.slice(k + 1)]];
  }
  const m = Math.min(model.startArguments.length, startArgs.length);
  for (let j = 0; j < m; j++)
    for (const c of model.values.shrink(model.startArguments[j], startArgs[j]))
      yield [[...startArgs.slice(0, j), c, ...startArgs.slice(j + 1)], steps];
}

async function shrinkRun(model, run, failure, budget) {
  while (budget > 0) {
    let improved = false;
    for (const candidate of shrinkCandidates(model, run)) {
      budget -= 1;
      if (budget <= 0) {
        improved = true; // stops like Python's break out of for-else
        break;
      }
      try {
        await simulate(model, new Map(), candidate);
      } catch (error) {
        if (error instanceof Invalid) continue;
        throw error;
      }
      const found = await execute(model, candidate);
      if (found !== null) {
        run = candidate;
        failure = found;
        improved = true;
        break;
      }
    }
    if (!improved) break;
  }
  return [run, failure];
}

function describeRun(model, run) {
  const [startArgs, steps] = run;
  const parts = ['start(' + startArgs.map(render).join(', ') + ')',
    ...steps.map(([i, args]) => model.steps[i].name + '(' + args.map(render).join(', ') + ')')];
  return parts.join('; ');
}

/**
 * Checks the system against its model on generated runs; a failure throws
 * an Error naming the shortest failing run found.
 */
export async function checkModelAsync(model, options = {}) {
  const {cases = 100, maxLength = 20, maxShrinks = 2000} = options;
  let seed = options.seed;
  if (seed === undefined || seed === null) seed = BigInt(globalThis.process?.env?.LAWSPEC_SEED ?? '0');
  const random = new SplitMix64(BigInt(seed));
  for (let c = 0; c < cases; c++) {
    const length = Number(random.below(BigInt(maxLength) + 1n));
    let run = await generateRun(model, random, length, 1 + c % 8, true);
    const failure = await execute(model, run);
    if (failure !== null) {
      let step, message;
      [run, [step, message]] = await shrinkRun(model, run, failure, maxShrinks);
      throw new Error(`model ${model.name} fails at step ${step} of ${describeRun(model, run)}: ${message}`);
    }
  }
}

// Parallel runs of a shared model. A case is a sequential prefix and one
// branch per thread, generated so that the model allows every interleaving
// of the branches (a search over each thread's position and the model state,
// memoized). The system runs the branches at the same time, as concurrent
// async calls that interleave where they await, each call's start and
// return recorded on one counter, with random yields around calls to shake
// out rare schedules. The history must be linearizable: some interleaving
// that keeps every call after those that returned before it started must
// give every result the model gives and leave the state it leaves (a
// Wing-Gong search, memoized on the same positions and model state). Each
// case runs several times.

const THREADS = 3;
const BRANCH = 5;

const positionKey = (positions, state) => positions.join(',') + '|' + render(state);
const advanced = (positions, i) => positions.map((k, j) => (j === i ? k + 1 : k));

/** Whether the model allows the prefix then every interleaving. */
async function parallelAllowed(model, prefix, branches) {
  const symbols = new Map();
  let state;
  try {
    const states = await simulate(model, symbols, prefix);
    state = states[states.length - 1];
  } catch (error) {
    if (error instanceof Invalid) return false;
    throw error;
  }
  const seen = new Set();
  const visit = async (positions, state) => {
    const key = positionKey(positions, state);
    if (seen.has(key)) return true;
    seen.add(key);
    for (let i = 0; i < branches.length; i++) {
      const k = positions[i];
      if (k < branches[i].length) {
        const [index, args] = branches[i][k];
        let after;
        try {
          [after] = await stepModel(model.commands[index], symbols, args, state);
        } catch (error) {
          if (error instanceof Invalid) return false;
          throw error;
        }
        if (!(await visit(advanced(positions, i), after))) return false;
      }
    }
    return true;
  };
  return visit(branches.map(() => 0), state);
}

async function generateBranch(model, random, state, length, size) {
  const symbols = new Map();
  const steps = [];
  for (let n = 0; n < length; n++) {
    const index = Number(random.below(BigInt(model.commands.length)));
    const command = model.commands[index];
    const args = command.arguments.map((d) => model.values.generate(d, random, size));
    try {
      [state] = await stepModel(command, symbols, args, state);
    } catch (error) {
      if (error instanceof Invalid) continue;
      throw error;
    }
    steps.push([index, args]);
  }
  return steps;
}

async function generateParallel(model, random, size, threads = THREADS, branchLength = BRANCH) {
  const prefix = await generateRun(model, random, Number(random.below(4n)), size);
  let state;
  try {
    const states = await simulate(model, new Map(), prefix);
    state = states[states.length - 1];
  } catch (error) {
    if (error instanceof Invalid) return [prefix, Array.from({length: threads}, () => [])];
    throw error;
  }
  const branches = [];
  for (let b = 0; b < threads; b++)
    branches.push(await generateBranch(model, random, state,
      1 + Number(random.below(BigInt(branchLength))), size));
  // Drop the last step of the longest branch (the first, among equals)
  // until every interleaving is allowed.
  while (!(await parallelAllowed(model, prefix, branches))) {
    let longest = 0;
    for (let i = 1; i < threads; i++) if (branches[i].length > branches[longest].length) longest = i;
    branches[longest] = branches[longest].slice(0, -1);
  }
  return [prefix, branches];
}

const nextTask = () => new Promise((resolve) => setTimeout(resolve, 0));

/**
 * Nothing, a microtask yield, or one or two macrotask yields (JavaScript
 * has no microsecond sleep; the draw matches the other targets). Nothing
 * returns null, so the caller does not await at all.
 */
function perturb(random) {
  const choice = random.below(4n);
  if (choice === 0n) return null;
  if (choice === 1n) return Promise.resolve();
  if (choice === 2n) return nextTask();
  return nextTask().then(nextTask);
}

/** null when the history is linearizable; otherwise what went wrong. */
async function executeParallel(model, testCase, shake) {
  const [prefix, branches] = testCase;
  const [startArgs, steps] = prefix;
  const symbols = new Map();
  let state;
  try {
    state = await model.startRun(symbols, ...startArgs);
    for (const [index, args] of steps) {
      const command = model.commands[index];
      const full = [...args];
      full.splice(command.state, 0, state);
      await command.run(symbols, ...full);
    }
  } catch (error) {
    return `the prefix raised ${errorName(error)}: ${errorMessage(error)}`;
  }
  let clock = 0;
  const tick = () => ++clock;
  const history = branches.map((b) => b.map(() => null));
  const errors = [];
  const branch = async (i) => {
    const own = new Map();
    const random = new SplitMix64(shake ^ (BigInt(i + 1) * 0x9E3779B97F4A7C15n));
    for (let k = 0; k < branches[i].length; k++) {
      const [index, args] = branches[i][k];
      const command = model.commands[index];
      const full = [...args];
      full.splice(command.state, 0, state);
      let pause = perturb(random);
      if (pause !== null) await pause;
      const called = tick();
      let result;
      try {
        result = await command.run(own, ...full);
      } catch (error) {
        errors.push(`${command.name} raised ${errorName(error)}: ${errorMessage(error)}`);
        result = null;
      }
      history[i][k] = [called, tick(), result];
      pause = perturb(random);
      if (pause !== null) await pause;
    }
  };
  await Promise.all(branches.map((_, i) => branch(i)));
  if (errors.length) return errors[0];
  const states = await simulate(model, symbols, prefix);
  const expected = states[states.length - 1];
  const final = model.abstract !== null ? await model.abstract(symbols, state) : null;
  if (await linearizable(model, symbols, branches, history, expected, final, state)) return null;
  const observed = [];
  branches.forEach((b, i) => b.forEach(([index], k) =>
    observed.push(`${branchName(i)}: ${model.commands[index].name}() returned ${render(history[i][k][2])}`)));
  return `no order of the parallel calls agrees with the model (${observed.join('; ')})`;
}

const branchName = (i) => String.fromCharCode(65 + i);

/**
 * Whether the history linearizes, with the final state and invariants the
 * model gives. For a set or map whose every call touches one key, each
 * key's calls are linearized separately (the keys are independent), one
 * group after another; otherwise all calls at once.
 */
async function linearizable(model, symbols, branches, history, expected, final, state) {
  const finish = async (modelState) => {
    if (final !== null && compareValues(final, modelState) !== 0) return false;
    for (const [kind, invariant] of model.invariants)
      if (!(await invariant(symbols, kind === 'model' ? modelState : state))) return false;
    return true;
  };
  if (!model.perKey) return linearize(model, symbols, branches, history, expected, finish);
  const groups = new Map();
  branches.forEach((branch, i) => branch.forEach(([index, args], k) => {
    const key = render(args[model.commands[index].key]);
    if (!groups.has(key)) groups.set(key, branches.map(() => []));
    groups.get(key)[i].push([branch[k], history[i][k]]);
  }));
  let modelState = expected;
  const keys = [...groups.keys()].sort((a, b) => (a < b ? -1 : a > b ? 1 : 0));
  for (const key of keys) {
    const parts = groups.get(key);
    const ends = [];
    const found = await linearize(model, symbols, parts.map((p) => p.map(([s]) => s)),
      parts.map((p) => p.map(([, h]) => h)), modelState, async (end) => {
        ends.push(end);
        return true;
      });
    if (!found) return false;
    modelState = ends[0];
  }
  return finish(modelState);
}

const CONSISTENT = {
  linearizable: 'linearizable', sequential: 'sequentially consistent',
  causal: 'causally consistent', eventual: 'eventually consistent',
};

/**
 * A Wing-Gong search: linearize, next, a call no pending call on another
 * thread returned before; memoized on positions and the model state.
 * finish judges each complete order's final model state.
 *
 * With weaker consistency: sequential drops real time (each thread's own
 * order remains); causal checks each thread's results alone, since threads
 * that never message each other see only their own calls; eventual checks
 * no results, only the final state.
 */
async function linearize(model, symbols, branches, history, expected, finish) {
  const mode = model.consistency;
  if (mode === 'causal') {
    for (let i = 0; i < branches.length; i++) {
      let state = expected;
      for (let k = 0; k < branches[i].length; k++) {
        const [index, args] = branches[i][k];
        const command = model.commands[index];
        let wanted;
        try {
          [state, wanted] = await stepModel(command, symbols, args, state);
        } catch (error) {
          if (error instanceof Invalid) return false;
          throw error;
        }
        if (!command.unit && compareValues(history[i][k][2], wanted) !== 0) return false;
      }
    }
    return true;
  }
  const seen = new Set();
  const visit = async (positions, modelState) => {
    const key = positionKey(positions, modelState);
    if (seen.has(key)) return false;
    seen.add(key);
    if (positions.every((k, i) => k === branches[i].length)) return finish(modelState);
    for (let i = 0; i < branches.length; i++) {
      const k = positions[i];
      if (k === branches[i].length) continue;
      const called = history[i][k][0];
      let blocked = false;
      if (mode === 'linearizable') for (let j = 0; j < branches.length; j++)
        if (j !== i && positions[j] < branches[j].length && history[j][positions[j]][1] < called) {
          blocked = true;
          break;
        }
      if (blocked) continue;
      const [index, args] = branches[i][k];
      const command = model.commands[index];
      let after, wanted;
      try {
        [after, wanted] = await stepModel(command, symbols, args, modelState);
      } catch (error) {
        if (error instanceof Invalid) continue;
        throw error;
      }
      if (mode !== 'eventual' && !command.unit && compareValues(history[i][k][2], wanted) !== 0) continue;
      if (await visit(advanced(positions, i), after)) return true;
    }
    return false;
  };
  return visit(branches.map(() => 0), expected);
}

async function parallelFails(model, testCase, repeats, shake) {
  for (let attempt = 0; attempt < repeats; attempt++) {
    const failure = await executeParallel(model, testCase, shake + BigInt(attempt));
    if (failure !== null) return failure;
  }
  return null;
}

async function shrinkParallel(model, testCase, failure, repeats, budget, shake) {
  while (budget > 0) {
    const [prefix, branches] = testCase;
    const [startArgs, steps] = prefix;
    const candidates = [];
    for (let k = 0; k < steps.length; k++)
      candidates.push([[startArgs, [...steps.slice(0, k), ...steps.slice(k + 1)]], branches]);
    for (let i = 0; i < branches.length; i++)
      for (let k = 0; k < branches[i].length; k++)
        candidates.push([prefix, branches.map((b, j) => (j !== i ? b : [...b.slice(0, k), ...b.slice(k + 1)]))]);
    // Then smaller arguments, branch by branch, step by step.
    for (let i = 0; i < branches.length; i++)
      branches[i].forEach(([index, args], k) => {
        const command = model.commands[index];
        const n = Math.min(command.arguments.length, args.length);
        for (let a = 0; a < n; a++)
          for (const c of model.values.shrink(command.arguments[a], args[a])) {
            const step = [index, [...args.slice(0, a), c, ...args.slice(a + 1)]];
            candidates.push([prefix, branches.map((b, j) => (j !== i ? b : [...b.slice(0, k), step, ...b.slice(k + 1)]))]);
          }
      });
    let improved = false;
    for (const candidate of candidates) {
      budget -= 1;
      if (budget <= 0) {
        improved = true; // stops like Python's break out of for-else
        break;
      }
      if (!(await parallelAllowed(model, ...candidate))) continue;
      const found = await parallelFails(model, candidate, repeats, shake);
      if (found !== null) {
        testCase = candidate;
        failure = found;
        improved = true;
        break;
      }
    }
    if (!improved) break;
  }
  return [testCase, failure];
}

function describeParallel(model, testCase) {
  const [prefix, branches] = testCase;
  const describe = (steps) => steps.map(([i, args]) =>
    model.commands[i].name + '(' + args.map(render).join(', ') + ')').join('; ');
  const parts = branches.map((b, i) => `${branchName(i)}: ${describe(b) || 'nothing'}`);
  return `${describeRun(model, prefix)}, then ${parts.slice(0, -1).join(', ')} and ` +
    `${parts[parts.length - 1]} at the same time`;
}

/**
 * Checks a shared model's histories under concurrency; a failure throws an
 * Error naming the smallest failing case found.
 */
export async function checkModelParallelAsync(model, options = {}) {
  const {cases = 50, repeats = 10, maxShrinks = 300, threads = THREADS, branchLength = BRANCH} = options;
  let seed = options.seed;
  if (seed === undefined || seed === null) seed = BigInt(globalThis.process?.env?.LAWSPEC_SEED ?? '0');
  const random = new SplitMix64(BigInt(seed) ^ 0x5BD1E995n);
  for (let c = 0; c < cases; c++) {
    let testCase = await generateParallel(model, random, 1 + c % 8, threads, branchLength);
    const shake = random.next();
    let failure = await parallelFails(model, testCase, repeats, shake);
    if (failure !== null) {
      [testCase, failure] = await shrinkParallel(model, testCase, failure,
        Math.max(2, Math.floor(repeats / 2)), maxShrinks, shake);
      throw new Error(`model ${model.name} is not ${CONSISTENT[model.consistency]}: ${describeParallel(model, testCase)}: ${failure}`);
    }
  }
}

// Scenarios: processes that drive a shared model's commands at the same time
// and talk over channels (see LawSpec.Core.Program for the spec). Each
// channel has a queue per direction; a process holds an end of a channel as
// [channel, side], the first branch of a par to use a channel taking side 0.
// A channel end sent over a channel moves to the receiver. Every command's
// call and return are stamped on one counter; the history must linearize
// against the model, and every expect must hold, on each of many schedules.
// Processes are async functions run together; a receive awaits the send.

const RECEIVE_TIMEOUT = 5000;
const TIMED_OUT_RECEIVE = Symbol('receive timed out');

/** A queue whose get awaits a put, or gives up after a timeout. */
class AsyncQueue {
  items = [];
  waiters = [];
  put(value) {
    const waiter = this.waiters.shift();
    if (waiter !== undefined) waiter(value);
    else this.items.push(value);
  }
  get(timeout) {
    if (this.items.length) return Promise.resolve(this.items.shift());
    return new Promise((resolve) => {
      const waiter = (value) => {
        clearTimeout(timer);
        resolve(value);
      };
      const timer = setTimeout(() => {
        const at = this.waiters.indexOf(waiter);
        if (at >= 0) this.waiters.splice(at, 1);
        resolve(TIMED_OUT_RECEIVE);
      }, timeout);
      this.waiters.push(waiter);
    });
  }
}

const GONE = Symbol('the other process ended');

class Channel {
  queues = [new AsyncQueue(), new AsyncQueue()];
  ended = [false, false];
  /** The next value for side: GONE once the other side has ended, or TIMED_OUT_RECEIVE. */
  async receive(side) {
    const value = await this.queues[1 - side].get(RECEIVE_TIMEOUT);
    if (value === GONE) this.queues[1 - side].put(GONE);
    return value;
  }
  /** A channel end sent to a process that has ended is given up. */
  send(side, value) {
    if (this.ended[1 - side] && value instanceof End) value.channel.gone(value.side);
    else this.queues[side].put(value);
  }
  /**
   * side's process has ended: the other side's receives that find nothing
   * more fail instead of waiting, and channel ends on their way to side are
   * given up too.
   */
  gone(side) {
    if (this.ended[side]) return;
    this.ended[side] = true;
    this.queues[side].put(GONE);
    const incoming = this.queues[1 - side].items;
    const stranded = [];
    while (incoming.length) {
      const value = incoming.shift();
      if (value instanceof End) stranded.push(value);
      else if (value === GONE) {
        incoming.unshift(value);
        break;
      }
    }
    for (const end of stranded) end.channel.gone(end.side);
  }
}

/**
 * A scenario channel whose two sides are endpoints on two nodes of a faulty
 * in-memory network. A channel end sent over it travels as its name, and
 * the receiver uses the end where it is (its owner).
 */
class NetScenarioChannel {
  name;
  registry;
  nodes;
  ends;
  done;
  constructor(network, name, steps, values, registry) {
    this.name = name;
    this.registry = registry;
    this.nodes = [0, 1].map((side) => new Node(network.transport(`${name}-${side}`)));
    const wire = (sends, d) => [sends, d[0] === 'end' ? ['text'] : d];
    this.ends = [this.nodes[0].listen(name, steps.map(([s, d]) => wire(s, d)), values)];
    this.ends.push(this.nodes[1].dial(`${this.nodes[0].address}/${name}`, steps.map(([s, d]) => wire(!s, d)), values));
    this.done = [false, false];
    registry.set(name, this);
  }
  send(side, value) {
    if (value instanceof End) value = `${value.channel.name}#${value.side}`;
    this.ends[side].send(side, value);
  }
  async receive(side) {
    let value;
    try {
      value = await this.ends[side].receive(side, RECEIVE_TIMEOUT);
    } catch (error) {
      if (error instanceof PeerFailed) return GONE;
      return TIMED_OUT_RECEIVE;
    }
    if (typeof value === 'string' && value.includes('#')) {
      const at = value.lastIndexOf('#');
      const owner = this.registry.get(value.slice(0, at));
      if (owner !== undefined) return new End(owner, Number(value.slice(at + 1)));
    }
    return value;
  }
  gone(side) {
    if (this.done[side]) return;
    this.done[side] = true;
    this.ends[side].abandon(side);
  }
  async close() {
    for (const node of this.nodes) await node.close();
  }
}

/**
 * A scenario's mailbox: any process sends, one receives. expected is how
 * many sends the scenario makes; a process that ends gives up the sends it
 * did not make, and a receive with nothing left to come resolves to GONE
 * instead of waiting. Over a network, messages go from a sender node to the
 * receiver's node, each send waiting until it is delivered.
 */
class ScenarioMailbox {
  name;
  expected;
  received = 0;
  abandoned = 0;
  items = [];
  clocks = [];
  waiters = [];
  nodes = [];
  inbox = null;
  remote = null;
  registry;
  constructor(name, expected, network = null, descriptor = null, values = null, registry = null) {
    this.name = name;
    this.expected = expected;
    this.registry = registry;
    if (network !== null) {
      const owner = new Node(network.transport(`${name}-owner`));
      const senders = new Node(network.transport(`${name}-senders`));
      this.nodes = [owner, senders];
      const d = descriptor[0] === 'end' ? ['text'] : descriptor;
      this.inbox = owner.mailbox(name, d, values);
      this.remote = senders.remoteMailbox(`${owner.address}/${name}`, d, values, 5);
    }
  }
  wake() {
    for (const waiter of this.waiters.splice(0)) waiter();
  }
  async send(value, clock) {
    if (this.inbox === null) {
      this.items.push([value, clock]);
      this.wake();
      return;
    }
    if (value instanceof End) value = `${value.channel.name}#${value.side}`;
    // The clock travels beside the network, in send order.
    this.clocks.push(clock);
    await this.remote.send(value);
    this.wake();
  }
  giveUp(count) {
    this.abandoned += count;
    this.wake();
  }
  /** [value, sender's clock], [GONE, empty clock], or TIMED_OUT_RECEIVE. */
  async receive() {
    const giveUp = Date.now() + RECEIVE_TIMEOUT;
    for (;;) {
      if (this.inbox === null) {
        if (this.items.length) {
          this.received++;
          return this.items.shift();
        }
        if (this.received + this.abandoned >= this.expected) return [GONE, new Map()];
        const left = giveUp - Date.now();
        if (left <= 0) return TIMED_OUT_RECEIVE;
        await Promise.race([new Promise((resolve) => this.waiters.push(resolve)), sleep(left)]);
        continue;
      }
      if (this.received + this.abandoned >= this.expected) return [GONE, new Map()];
      let value;
      try {
        value = await this.inbox.receiveAsync(20);
      } catch {
        if (Date.now() > giveUp) return TIMED_OUT_RECEIVE;
        continue;
      }
      this.received++;
      const clock = this.clocks.shift() ?? new Map();
      if (typeof value === 'string' && value.includes('#')) {
        const at = value.lastIndexOf('#');
        const owner = this.registry.get(value.slice(0, at));
        if (owner !== undefined) value = new End(owner, Number(value.slice(at + 1)));
      }
      return [value, clock];
    }
  }
  async close() {
    for (const node of this.nodes) await node.close();
  }
}

/** How many times these acts (not nested pars) send to name. */
function scenarioSends(acts, name) {
  return acts.filter((act) => act[0] === 'send' && String(act[1]) === name).length;
}

/** How many sends to name the whole program makes. */
function allSends(acts, name) {
  let total = 0;
  for (const act of acts) {
    if (act[0] === 'send' && String(act[1]) === name) total++;
    else if (act[0] === 'par') for (const branch of act.slice(1)) total += allSends(branch.slice(1), name);
  }
  return total;
}

/** Every process of a par, outermost and first first (not or else). */
function scenarioProcesses(acts, found) {
  for (const act of acts)
    if (act[0] === 'par')
      for (const branch of act.slice(1)) {
        found.push(branch);
        scenarioProcesses(branch.slice(1), found);
      }
  return found;
}

/** A channel end in transit or held by a process. */
class End {
  channel;
  side;
  constructor(channel, side) {
    this.channel = channel;
    this.side = side;
  }
}

/** The names an act list sends, receives or sends away, with nested pars. */
function actsChannels(acts) {
  const names = [];
  for (const act of acts) {
    if (act[0] === 'send') {
      names.push(String(act[1]));
      if (act[2][0] === 'var') names.push(String(act[2][1]));
    } else if (act[0] === 'receive') {
      names.push(String(act[1]));
    } else if (act[0] === 'receiveor') {
      names.push(String(act[1]));
      names.push(...actsChannels(act[3].slice(1)));
    } else if (act[0] === 'par') {
      for (const branch of act.slice(1)) names.push(...actsChannels(branch.slice(1)));
    }
  }
  return names;
}

function constant(form) {
  const kind = form[0];
  if (kind === 'int') return form[1];
  if (kind === 'text') return String(form[1]);
  if (kind === 'bool') return form[1] === 'true';
  return new DataValue(String(form[1]), []);
}

async function runScenario(model, spec, shake, crash = false, network = false) {
  const forms = readDescriptor(spec);
  const title = String(forms[0][1]);
  const names = forms.find((f) => f[0] === 'channels').slice(1).map(String);
  const body = forms.find((f) => f[0] === 'process').slice(1);
  const wire = forms.find((f) => f[0] === 'wire');
  const boxes = forms.filter((f) => f[0] === 'mailboxes').flatMap((f) => f.slice(1).map(String));
  let channels, mailboxes;
  if (network && wire !== undefined) {
    // Loss, duplication and delay (which reorders); the channels' numbered,
    // acknowledged frames must hide them all.
    const net = new MemoryNetwork({seed: (BigInt(shake) ^ 0x7F4A7C159E3779B9n) & MASK64, loss: 0.1, duplicate: 0.1, delay: 0.002});
    const types = new Values(new Map(wire.slice(1).filter((f) => f[0] === 'data').map((f) => [String(f[1]), f])));
    const steps = new Map(wire.slice(1).filter((f) => f[0] === 'channel')
      .map((f) => [String(f[1]), f.slice(2).map((s) => [s[0] === 'send', s[1]])]));
    const registry = new Map();
    channels = new Map(names.map((name) => [name, new NetScenarioChannel(net, name, steps.get(name), types, registry)]));
    const kinds = new Map(wire.slice(1).filter((f) => f[0] === 'mailbox').map((f) => [String(f[1]), f[2]]));
    mailboxes = new Map(boxes.map((m) => [m, kinds.has(m)
      ? new ScenarioMailbox(m, allSends(body, m), net, kinds.get(m), types, registry)
      : new ScenarioMailbox(m, allSends(body, m))]));
  } else {
    channels = new Map(names.map((name) => [name, new Channel()]));
    mailboxes = new Map(boxes.map((m) => [m, new ScenarioMailbox(m, allSends(body, m))]));
  }
  const commands = new Map(model.commands.map((c) => [c.name, c]));
  const symbols = new Map();
  const startArgs = model.startArguments.map((d) => model.values.minimal(d));
  const state = await model.startRun(symbols, ...startArgs);
  const expected = await model.startModel(symbols, ...startArgs);
  let clock = 0;
  const tick = () => ++clock;
  const history = [];
  const failures = [];
  // The crashed process (a par's branch) and the act it crashes before.
  const processes = scenarioProcesses(body, []);
  let victim = null;
  if (crash && processes.length) {
    const chooser = new SplitMix64(shake ^ 0xC3A5C85C97CB3127n);
    const branch = processes[Number(chooser.below(BigInt(processes.length)))];
    victim = [branch, Number(chooser.below(BigInt(branch.length - 1 + 1)))];
  }
  const crashesAt = (identity, index) => victim !== null && victim[0] === identity && victim[1] === index;

  // Vector clocks: each value sent carries its sender's clock (kept here, in
  // order per channel direction), so calls can be ordered by what happened
  // before what. A process is named by its par branch (the root is 'root').
  const stamps = new Map();
  const processNames = new Map();
  const nameOf = (identity) => {
    if (identity === null) return 'root';
    if (!processNames.has(identity)) processNames.set(identity, `p${processNames.size}`);
    return processNames.get(identity);
  };
  const bump = (clock, me) => clock.set(me, (clock.get(me) ?? 0) + 1);
  const stampFor = (channel, side) => {
    if (!stamps.has(channel)) stamps.set(channel, [[], []]);
    return stamps.get(channel)[side];
  };
  const merge = (clock, other) => {
    for (const [p, n] of other) clock.set(p, Math.max(clock.get(p) ?? 0, n));
  };

  // 'done' or 'failed'; either way, the ends still held are given up.
  const runProcess = async (acts, env, ends, random, identity = null, clock = new Map()) => {
    const sent = new Map([...mailboxes.keys()].map((m) => [m, 0]));
    try {
      return await steps(acts, env, ends, random, identity, clock, nameOf(identity), sent);
    } finally {
      for (const [channel, side] of ends.values()) channel.gone(side);
      // Sends this process will never make.
      for (const [m, box] of mailboxes) {
        const missing = scenarioSends(acts, m) - sent.get(m);
        if (missing > 0) box.giveUp(missing);
      }
    }
  };

  const steps = async (acts, env, ends, random, identity, clock, me, sent) => {
    const own = new Map();
    for (let index = 0; index < acts.length; index++) {
      const act = acts[index];
      if (failures.length) return 'failed';
      if (crashesAt(identity, index)) return 'failed';
      const kind = act[0];
      if (kind === 'call') {
        const command = commands.get(String(act[1]));
        const args = act.slice(3).map((o) => (o[0] === 'var' ? env.get(String(o[1])) : constant(o)));
        const full = [...args];
        full.splice(command.state, 0, state);
        const pause = perturb(random);
        if (pause !== null) await pause;
        bump(clock, me);
        const atCall = new Map(clock);
        const called = tick();
        let result;
        try {
          result = await command.run(own, ...full);
        } catch (error) {
          failures.push(`${command.name} raised ${errorName(error)}: ${errorMessage(error)}`);
          return 'failed';
        }
        const returned = tick();
        bump(clock, me);
        history.push([command, args, result, called, returned, me, atCall, new Map(clock)]);
        if (act[2] !== null && act[2] !== '_') env.set(String(act[2]), result);
      } else if (kind === 'send' && mailboxes.has(String(act[1]))) {
        const operand = act[2];
        let value;
        if (operand[0] === 'var' && ends.has(String(operand[1]))) {
          const name = String(operand[1]);
          value = new End(...ends.get(name));
          ends.delete(name);
        } else {
          value = operand[0] === 'var' ? env.get(String(operand[1])) : constant(operand);
        }
        const pause = perturb(random);
        if (pause !== null) await pause;
        bump(clock, me);
        try {
          await mailboxes.get(String(act[1])).send(value, new Map(clock));
        } catch (error) {
          failures.push(`a send to mailbox ${act[1]} failed: ${errorMessage(error)}`);
          return 'failed';
        }
        sent.set(String(act[1]), sent.get(String(act[1])) + 1);
      } else if ((kind === 'receive' || kind === 'receiveor') && mailboxes.has(String(act[1]))) {
        const got = await mailboxes.get(String(act[1])).receive();
        if (got === TIMED_OUT_RECEIVE) {
          failures.push(`a receive on mailbox ${act[1]} waited too long: the processes are blocked`);
          return 'failed';
        }
        const [value, carried] = got;
        if (value === GONE) {
          if (kind === 'receive') return 'failed';
          return steps(act[3].slice(1), env, ends, random, null, clock, me, sent);
        }
        merge(clock, carried);
        bump(clock, me);
        if (value instanceof End) ends.set(String(act[2]), [value.channel, value.side]);
        else env.set(String(act[2]), value);
      } else if (kind === 'send') {
        const [channel, side] = ends.get(String(act[1]));
        const operand = act[2];
        let value;
        if (operand[0] === 'var' && ends.has(String(operand[1]))) {
          const name = String(operand[1]);
          value = new End(...ends.get(name));
          ends.delete(name);
        } else {
          value = operand[0] === 'var' ? env.get(String(operand[1])) : constant(operand);
        }
        const pause = perturb(random);
        if (pause !== null) await pause;
        bump(clock, me);
        stampFor(channel, side).push(new Map(clock));
        channel.send(side, value);
      } else if (kind === 'receive' || kind === 'receiveor') {
        const [channel, side] = ends.get(String(act[1]));
        const value = await channel.receive(side);
        if (value === TIMED_OUT_RECEIVE) {
          failures.push(`a receive on ${act[1]} waited too long: the processes are blocked`);
          return 'failed';
        }
        if (value === GONE) {
          // The other process ended: or else runs instead of the rest;
          // without it, this process fails too.
          if (kind === 'receive') return 'failed';
          ends.delete(String(act[1]));
          return steps(act[3].slice(1), env, ends, random, null, clock, me, sent);
        }
        const stamped = stampFor(channel, 1 - side).shift();
        if (stamped !== undefined) merge(clock, stamped);
        bump(clock, me);
        if (value instanceof End) ends.set(String(act[2]), [value.channel, value.side]);
        else env.set(String(act[2]), value);
      } else if (kind === 'par') {
        const branches = act.slice(1);
        const owned = new Map();
        branches.forEach((branch, i) => {
          for (const name of actsChannels(branch.slice(1))) {
            if (!owned.has(name)) owned.set(name, []);
            if (!owned.get(name).includes(i)) owned.get(name).push(i);
          }
        });
        const clocks = branches.map(() => new Map(clock));
        const running = branches.map((branch, i) => {
          const mine = new Map();
          for (const [name, users] of owned) {
            if (!users.includes(i)) continue;
            if (ends.has(name)) {
              mine.set(name, ends.get(name));
              ends.delete(name);
            } else if (channels.has(name)) {
              mine.set(name, [channels.get(name), users.indexOf(i)]);
            }
          }
          return runProcess(branch.slice(1), new Map(env), mine,
            new SplitMix64(shake ^ ((BigInt(i + 1) * 0x9E3779B97F4A7C15n) & MASK64)), branch, clocks[i]);
        });
        const settled = await Promise.allSettled(running);
        for (const child of clocks) merge(clock, child);
        bump(clock, me);
        const rejected = settled.find((s) => s.status === 'rejected');
        if (rejected !== undefined) throw rejected.reason;
        // A failed branch fails the process that ran the par.
        if (settled.some((s) => s.value === 'failed')) return 'failed';
      } else if (kind === 'expect') {
        const name = String(act[1]);
        const actual = env.get(name), wanted = constant(act[2]);
        if (actual === undefined || actual === null || compareValues(actual, wanted) !== 0) {
          failures.push(`expect ${name} = ${render(wanted)} failed: ${name} is ${render(actual)}`);
          return 'failed';
        }
      }
    }
    if (crashesAt(identity, acts.length)) return 'failed';
    return 'done';
  };

  const outcome = await runProcess(body, new Map(), new Map(), new SplitMix64(shake));
  for (const channel of channels.values()) if (channel instanceof NetScenarioChannel) await channel.close();
  for (const box of mailboxes.values()) await box.close();
  if (failures.length) return [title, failures[0] + (victim !== null ? ' (with a process crashed)' : '')];
  if (outcome === 'failed' && victim === null) return [title, 'a process failed'];
  const final = model.abstract !== null ? await model.abstract(symbols, state) : null;
  if (!(await linearizesHistory(model, symbols, history, expected, final, state))) {
    const observed = [...history].sort((a, b) => a[3] - b[3])
      .map(([c, args, r]) => `${c.name}(${args.map(render).join(', ')}) returned ${render(r)}`)
      .join('; ');
    return [title, `the calls are not ${CONSISTENT[model.consistency]} with the model (${observed})`];
  }
  return [title, null];
}

/**
 * Whether call a returned before call b began, as far as messages tell: a's
 * return clock is at or below b's call clock everywhere.
 */
function happenedBefore(a, b) {
  for (const [p, n] of a[7]) if ((b[6].get(p) ?? 0) < n) return false;
  return true;
}

/**
 * A Wing-Gong search over the scenario's calls, memoized on the calls done
 * and the state. Each call is [command, args, result, called, returned,
 * process, call clock, return clock]. Linearizable: next, a call no pending
 * call returned before (real time). Sequential: next, a call every call that
 * happened before it (its process's order, and messages) is done. Causal:
 * each process's results from an order of what happened before them.
 * Eventual: no results, only the final state.
 */
async function linearizesHistory(model, symbols, history, expected, final, state) {
  const mode = model.consistency;
  const count = history.length;
  const before = (j, i) => (mode === 'linearizable' ? history[j][4] < history[i][3] : happenedBefore(history[j], history[i]));
  const bit = (i) => 1n << BigInt(i);
  const search = async (members, checked, judgeFinal) => {
    const seen = new Set();
    let full = 0n;
    for (const i of members) full |= bit(i);
    const visit = async (done, modelState) => {
      const key = `${done}|${render(modelState)}`;
      if (seen.has(key)) return false;
      seen.add(key);
      if (done === full) {
        if (!judgeFinal) return true;
        if (final !== null && compareValues(final, modelState) !== 0) return false;
        for (const [kind, invariant] of model.invariants)
          if (!(await invariant(symbols, kind === 'model' ? modelState : state))) return false;
        return true;
      }
      for (const i of members) {
        if (done & bit(i)) continue;
        if (members.some((j) => j !== i && !(done & bit(j)) && before(j, i))) continue;
        const [command, args, result] = history[i];
        let after, wanted;
        try {
          [after, wanted] = await stepModel(command, symbols, args, modelState);
        } catch (error) {
          if (error instanceof Invalid) continue;
          throw error;
        }
        if (checked.has(i) && !command.unit && compareValues(result, wanted) !== 0) continue;
        if (await visit(done | bit(i), after)) return true;
      }
      return false;
    };
    return visit(0n, expected);
  };
  const everything = history.map((_, i) => i);
  if (mode === 'causal') {
    for (const process of new Set(history.map((h) => h[5]))) {
      const own = everything.filter((i) => history[i][5] === process);
      const seenBy = everything.filter((j) => own.includes(j) ||
        own.some((i) => i !== j && happenedBefore(history[j], history[i])));
      if (!(await search(seenBy, new Set(own), false))) return false;
    }
    return true;
  }
  return search(everything, mode === 'eventual' ? new Set() : new Set(everything), true);
}

/** Runs a scenario on many schedules; a failure throws an Error. */
export async function checkScenarioAsync(model, spec, options = {}) {
  const {runs = 30} = options;
  let seed = options.seed;
  if (seed === undefined || seed === null) seed = BigInt(globalThis.process?.env?.LAWSPEC_SEED ?? '0');
  const random = new SplitMix64(BigInt(seed) ^ 0x2545F4914F6CDD1Dn);
  for (let r = 0; r < runs; r++) {
    // Every third run crashes one process of a par at a random point, and
    // every third other one sends each channel over a faulty network.
    const [title, failure] = await runScenario(model, spec, random.next(), r % 3 === 2, r % 3 === 1);
    if (failure !== null) throw new Error(`scenario ${title} fails: ${failure}`);
  }
}

// Sessions: the runtime behind the typed channel ends generated for
// implementation code (src/lawspec_sessions.*, see LawSpec.Sessions). A
// channel carries values both ways between its two ends, side 0 (a
// protocol's first end) and side 1 (its second). Generated ends talk to a
// channel only through send(side, value), receive(side) and
// receiveNow(side), so a networked transport can stand in for it.

const SPENT_END = 'this end was already used; use the end its last step returned';

/**
 * A receive whose other end gave up: its process failed, or it called
 * abandon(). Catch it to handle the failure (or else); otherwise this
 * process fails too.
 */
export class PeerFailed extends Error {
  constructor(message = 'the other end gave up the conversation (its process failed or abandoned it)') {
    super(message);
    this.name = 'PeerFailed';
  }
}

const ABANDONED = Symbol('abandoned');

/** An in-process channel: one queue per direction; a receive awaits a send. */
export class SessionChannel {
  #queues = [[], []];
  #waiters = [[], []];

  /** Sends a value from the given side to the other side. */
  send(side, value) {
    const to = 1 - side;
    const waiter = this.#waiters[to].shift();
    if (waiter !== undefined) waiter(value);
    else this.#queues[to].push(value);
  }

  /**
   * Resolves to the next value sent to the given side, waiting for it;
   * rejects with PeerFailed once the other side has given up and nothing
   * is left.
   */
  receive(side) {
    const take = (value) => {
      if (value !== ABANDONED) return value;
      this.#queues[side].unshift(ABANDONED);
      throw new PeerFailed();
    };
    if (this.#queues[side].length) {
      try {
        return Promise.resolve(take(this.#queues[side].shift()));
      } catch (error) {
        return Promise.reject(error);
      }
    }
    return new Promise((resolve) => this.#waiters[side].push(resolve)).then(take);
  }

  /** The next value already sent to the given side, without waiting. */
  receiveNow(side) {
    if (!this.#queues[side].length)
      throw new Error('nothing has been sent to this end yet; await receive() instead');
    const value = this.#queues[side].shift();
    if (value === ABANDONED) {
      this.#queues[side].unshift(ABANDONED);
      throw new PeerFailed();
    }
    return value;
  }

  /** side gives up: the other side's receives fail after the values already sent. */
  abandon(side) {
    this.send(side, ABANDONED);
  }
}

/** A fresh in-process channel. */
export function channel() {
  return new SessionChannel();
}

/**
 * One end of a channel at one step of a protocol. Each end is used once:
 * its send or receive returns the end for the next step.
 */
export class SessionEnd {
  #channel;
  #side;
  #used = false;

  constructor(channel, side) {
    this.#channel = channel;
    this.#side = side;
  }

  /** Marks this end used, giving its channel and side. */
  use() {
    if (this.#used) throw new Error(SPENT_END);
    this.#used = true;
    return [this.#channel, this.#side];
  }

  /**
   * Gives up the conversation: the other end's receives fail with
   * PeerFailed once it has received what was already sent.
   */
  abandon() {
    const [channel, side] = this.use();
    channel.abandon(side);
  }

  /** A failed process gives up the ends it was given, used or not. */
  _giveUp() {
    this.#channel.abandon(this.#side);
  }
}

/** A value to send: an end sent over a channel moves to the receiver. */
function sendable(value) {
  if (!(value instanceof SessionEnd)) return value;
  const [channel, side] = value.use();
  return new value.constructor(channel, side);
}

/** Sends value on end, returning the next end, an instance of Next. */
export function sendOn(end, value, Next) {
  const [channel, side] = end.use();
  channel.send(side, sendable(value));
  return new Next(channel, side);
}

/** Resolves to [value, next end] once the other end has sent the value. */
export async function receiveOn(end, Next) {
  const [channel, side] = end.use();
  const value = await channel.receive(side);
  return [value, new Next(channel, side)];
}

/** [value, next end] for a value already sent; throws if none was sent yet. */
export function receiveNowOn(end, Next) {
  const [channel, side] = end.use();
  return [channel.receiveNow(side), new Next(channel, side)];
}

/** A new channel's two ends, of the protocol's First and Second start classes. */
export function openSession(First, Second, transport = channel()) {
  return [new First(transport, 0), new Second(transport, 1)];
}

/**
 * Starts fn(...args) as its own process. join() resolves to its result or
 * rejects with its error; a failure not joined is not reported.
 */
export function spawn(fn, ...args) {
  const result = Promise.resolve().then(() => fn(...args));
  // A failed process gives up the channel ends it was given.
  result.catch(() => {
    for (const arg of args) if (arg instanceof SessionEnd) arg._giveUp();
  });
  return Object.freeze({join: () => result});
}

/** Runs async functions at once; resolves to their results, or rejects with the first failure. */
export function par(...fns) {
  return Promise.all(fns.map((fn) => Promise.resolve().then(fn)));
}

// Distribution. Values cross the network in a canonical binary encoding
// driven by their type descriptor (the same descriptors as generation), so
// no tags are sent and every target writes the same bytes:
//   int: zigzag LEB128 of the integer (any size)      bool: 0 or 1
//   text, bytes: LEB128 length, then UTF-8 or raw     unit: nothing
//   list: LEB128 count, then items                     maybe: 0, or 1 then the value
//   either: 0 then left, or 1 then right               data: LEB128 constructor index, then fields
// A node sends frames over a Transport (in memory, TCP or HTTP): kind,
// entity name, the sender's address, an id and a payload. Everything that
// waits on the network returns a Promise.

/** Bytes that are not an encoding of a value of the expected type. */
export class WireError extends Error {
  constructor(message) {
    super(message);
    this.name = 'WireError';
  }
}

/** A node could not be reached, or did not answer in time. */
export class Unreachable extends Error {
  constructor(message) {
    super(message);
    this.name = 'Unreachable';
  }
}

const UTF8 = new TextEncoder();
const STRICT_UTF8 = new TextDecoder('utf-8', {fatal: true});

function putVarint(out, n) {
  for (;;) {
    const byte = Number(n & 0x7Fn);
    n >>= 7n;
    if (n) out.push(byte | 0x80);
    else {
      out.push(byte);
      return;
    }
  }
}

function getVarint(buf, pos) {
  let result = 0n, shift = 0n;
  for (;;) {
    if (pos >= buf.length) throw new WireError('the bytes end in the middle of a value');
    const byte = buf[pos++];
    result |= BigInt(byte & 0x7F) << shift;
    if (byte < 0x80) return [result, pos];
    shift += 7n;
  }
}

const asBig = (v) => (typeof v === 'number' && Number.isInteger(v) ? BigInt(v) : v);

function wirePut(values, d, v, out) {
  d = values.resolve(d);
  switch (d[0]) {
    case 'int': {
      v = asBig(v);
      const lo = d[2], hi = d[3];
      if (typeof v !== 'bigint' || (lo !== null && lo !== undefined && v < lo) || (hi !== null && hi !== undefined && v > hi))
        throw new WireError(`${render(v)} is not a ${d[1]}`);
      putVarint(out, v >= 0n ? v * 2n : -v * 2n - 1n);
      return;
    }
    case 'bool':
      out.push(v ? 1 : 0);
      return;
    case 'text':
    case 'end':
    case 'bytes': {
      const raw = d[0] === 'bytes' ? v : UTF8.encode(v);
      putVarint(out, BigInt(raw.length));
      for (const b of raw) out.push(b);
      return;
    }
    case 'unit':
      return;
    case 'list':
      putVarint(out, BigInt(v.length));
      for (const item of v) wirePut(values, d[1], item, out);
      return;
    case 'maybe':
      if (v.tag.endsWith('Nothing')) out.push(0);
      else {
        out.push(1);
        wirePut(values, d[1], v.fields[0], out);
      }
      return;
    case 'either': {
      const left = v.tag.endsWith('Left');
      out.push(left ? 0 : 1);
      wirePut(values, left ? d[1] : d[2], v.fields[0], out);
      return;
    }
    case 'data': {
      const ctors = d.slice(2);
      const index = ctors.findIndex((c) => String(c[1]) === v.tag);
      if (index < 0) throw new WireError(`${v.tag} is not a constructor of ${d[1]}`);
      putVarint(out, BigInt(index));
      ctors[index].slice(2).forEach((fd, i) => wirePut(values, fd, v.fields[i], out));
      return;
    }
  }
  throw new WireError('unknown descriptor ' + render(d));
}

function wireGet(values, d, buf, pos) {
  d = values.resolve(d);
  switch (d[0]) {
    case 'int': {
      let z;
      [z, pos] = getVarint(buf, pos);
      const v = z % 2n === 0n ? z / 2n : -(z + 1n) / 2n;
      const lo = d[2], hi = d[3];
      if ((lo !== null && lo !== undefined && v < lo) || (hi !== null && hi !== undefined && v > hi))
        throw new WireError(`${v} is out of range for ${d[1]}`);
      return [v, pos];
    }
    case 'bool':
      if (pos >= buf.length || buf[pos] > 1) throw new WireError('not a Bool');
      return [buf[pos] === 1, pos + 1];
    case 'text':
    case 'end':
    case 'bytes': {
      let n;
      [n, pos] = getVarint(buf, pos);
      const end = pos + Number(n);
      if (end > buf.length) throw new WireError('the bytes end in the middle of a value');
      const raw = buf.slice(pos, end);
      if (d[0] === 'bytes') return [raw, end];
      try {
        return [STRICT_UTF8.decode(raw), end];
      } catch {
        throw new WireError('text that is not UTF-8');
      }
    }
    case 'unit':
      return [UNIT, pos];
    case 'list': {
      let n;
      [n, pos] = getVarint(buf, pos);
      const items = [];
      for (let i = 0n; i < n; i++) {
        let item;
        [item, pos] = wireGet(values, d[1], buf, pos);
        items.push(item);
      }
      return [items, pos];
    }
    case 'maybe':
    case 'either': {
      if (pos >= buf.length || buf[pos] > 1) throw new WireError(`not a ${d[0] === 'maybe' ? 'Maybe' : 'Either'}`);
      const which = buf[pos++];
      if (d[0] === 'maybe') {
        if (which === 0) return [new DataValue('Maybe::Nothing', []), pos];
        const [v, next] = wireGet(values, d[1], buf, pos);
        return [new DataValue('Maybe::Just', [v]), next];
      }
      const [v, next] = wireGet(values, which === 0 ? d[1] : d[2], buf, pos);
      return [new DataValue(which === 0 ? 'Either::Left' : 'Either::Right', [v]), next];
    }
    case 'data': {
      let index;
      [index, pos] = getVarint(buf, pos);
      const ctors = d.slice(2);
      if (index >= BigInt(ctors.length)) throw new WireError(`no constructor ${index} in ${d[1]}`);
      const fields = [];
      for (const fd of ctors[Number(index)].slice(2)) {
        let v;
        [v, pos] = wireGet(values, fd, buf, pos);
        fields.push(v);
      }
      return [new DataValue(String(ctors[Number(index)][1]), fields), pos];
    }
  }
  throw new WireError('unknown descriptor ' + render(d));
}

/** The value's canonical bytes. */
export function wireEncode(values, d, v) {
  const out = [];
  wirePut(values, d, v, out);
  return Uint8Array.from(out);
}

/** The value encoded by exactly these bytes. */
export function wireDecode(values, d, data) {
  const [v, pos] = wireGet(values, d, data, 0);
  if (pos !== data.length) throw new WireError('extra bytes after the value');
  return v;
}

const hex = (bytes) => Array.from(bytes, (b) => b.toString(16).padStart(2, '0')).join('');

/** count values generated from one seed, encoded, in hexadecimal. */
export function wireEncoded(text, seed, size, count) {
  const [values, d] = valuesFrom(text);
  const random = new SplitMix64(BigInt(seed));
  return Array.from({length: Number(count)}, () => hex(wireEncode(values, d, values.generate(d, random, size))));
}

/** Whether count generated values decode to themselves. */
export function wireRoundTrips(text, seed, size, count) {
  const [values, d] = valuesFrom(text);
  const random = new SplitMix64(BigInt(seed));
  for (let i = 0; i < Number(count); i++) {
    const v = values.generate(d, random, size);
    if (render(wireDecode(values, d, wireEncode(values, d, v))) !== render(v)) return false;
  }
  return true;
}

const NO_TYPES = new Values(new Map());
const D_TEXT = ['text'];
const D_ID = ['int', 'UInt64', 0n, null];
const D_SEQ = ['int', 'Int64', null, null];
const FRAME = [D_TEXT, D_TEXT, D_TEXT, D_ID, ['bytes']];

function concatBytes(...parts) {
  const total = parts.reduce((n, p) => n + p.length, 0);
  const out = new Uint8Array(total);
  let at = 0;
  for (const p of parts) {
    out.set(p, at);
    at += p.length;
  }
  return out;
}

function frameEncode(kind, to, source, ident, payload) {
  const out = [];
  [kind, to, source, BigInt(ident), payload].forEach((v, i) => wirePut(NO_TYPES, FRAME[i], v, out));
  return Uint8Array.from(out);
}

function frameDecode(data) {
  let pos = 0;
  const fields = FRAME.map((d) => {
    let v;
    [v, pos] = wireGet(NO_TYPES, d, data, pos);
    return v;
  });
  if (pos !== data.length) throw new WireError('extra bytes after a frame');
  return fields;
}

/** 'tcp://host:port/name' as ['tcp://host:port', 'name']. */
function splitAddress(address) {
  const at = address.lastIndexOf('/');
  const node = address.slice(0, at), name = address.slice(at + 1);
  if (at < 0 || !node.includes('://')) throw new Error(`${address} is not an address such as tcp://127.0.0.1:7000/name`);
  return [node, name];
}

const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

/**
 * Moves frames between nodes. start(deliver) begins calling deliver(frame)
 * for every frame that arrives; send(node, frame) sends one to the node at
 * that address, best effort (a Promise, rejecting with Unreachable); close()
 * stops.
 */
export class Transport {
  address = null;
  start(deliver) { throw new Error('not implemented'); }
  async send(node, frame) { throw new Error('not implemented'); }
  async close() {}
}

/**
 * Nodes in one process, with faults for testing: each frame may be lost or
 * duplicated, and is delayed by up to delay seconds (so frames can overtake
 * each other); partition(...) cuts nodes off until heal().
 */
export class MemoryNetwork {
  random;
  loss;
  duplicate;
  delay;
  nodes;
  groups;
  recorded;
  /** With record, every record sent is kept in recorded, as the network saw it. */
  constructor({seed = 0n, loss = 0, duplicate = 0, delay = 0, record = false} = {}) {
    this.random = new SplitMix64(BigInt(seed));
    this.loss = loss;
    this.duplicate = duplicate;
    this.delay = delay;
    this.nodes = new Map();
    this.groups = null;
    this.recorded = record ? [] : null;
  }
  transport(name) {
    return new MemoryTransport(this, 'mem://' + name);
  }
  /**
   * A transport whose node skips the handshake and sends frames in the
   * clear: for tests of the frame layer only. Only an in-memory network
   * makes one, and no configuration selects it.
   */
  insecureTransportForTests(name) {
    return new InsecureMemoryTransport(this, 'mem://' + name);
  }
  /** Only nodes named in the same group reach each other. */
  partition(...groups) {
    this.groups = groups.map((g) => new Set(g.map((n) => 'mem://' + n)));
  }
  heal() {
    this.groups = null;
  }
  chance(p) {
    return p > 0 && Number(this.random.below(1n << 30n)) < p * 2 ** 30;
  }
  async send(source, node, frame) {
    if (this.recorded !== null) this.recorded.push(Uint8Array.from(frame));
    const deliver = this.nodes.get(node);
    if (deliver === undefined) throw new Unreachable(`no node at ${node}`);
    if (this.groups !== null && !this.groups.some((g) => g.has(source) && g.has(node))) return;
    if (this.chance(this.loss)) return;
    const copies = this.chance(this.duplicate) ? 2 : 1;
    for (let i = 0; i < copies; i++) {
      const wait = Number(this.random.below(1001n)) * this.delay;
      setTimeout(() => deliver(frame), wait);
    }
  }
}

class MemoryTransport extends Transport {
  network;
  constructor(network, address) {
    super();
    this.network = network;
    this.address = address;
  }
  start(deliver) {
    this.network.nodes.set(this.address, deliver);
  }
  send(node, frame) {
    return this.network.send(this.address, node, frame);
  }
  async close() {
    this.network.nodes.delete(this.address);
  }
}

/** In memory, without the handshake: tests only. */
export class InsecureMemoryTransport extends MemoryTransport {}

/**
 * Frames over TCP, each a 4-byte big-endian length then the frame. port 0
 * picks a free port; the address is tcp://host:port. Create one with
 * `await TcpTransport.listen(host, port)`.
 */
export class TcpTransport extends Transport {
  net;
  deliver;
  connections;
  sockets;
  server;
  static async listen(host = '127.0.0.1', port = 0) {
    const net = await import('node:net');
    const transport = new TcpTransport();
    transport.net = net;
    transport.deliver = null;
    transport.connections = new Map();
    transport.sockets = new Set();
    transport.server = net.createServer((socket) => transport.read(socket));
    await new Promise((resolve, reject) => {
      transport.server.once('error', reject);
      transport.server.listen(port, host, resolve);
    });
    transport.address = `tcp://${host}:${transport.server.address().port}`;
    return transport;
  }
  read(socket) {
    this.sockets.add(socket);
    let buffer = new Uint8Array(0);
    socket.on('data', (chunk) => {
      buffer = concatBytes(buffer, chunk);
      while (buffer.length >= 4) {
        const n = new DataView(buffer.buffer, buffer.byteOffset, 4).getUint32(0);
        if (buffer.length < 4 + n) break;
        const frame = buffer.slice(4, 4 + n);
        buffer = buffer.slice(4 + n);
        if (this.deliver !== null) this.deliver(frame);
      }
    });
    socket.on('error', () => {});
    socket.on('close', () => this.sockets.delete(socket));
  }
  start(deliver) {
    this.deliver = deliver;
  }
  connect(node) {
    let pending = this.connections.get(node);
    if (pending === undefined) {
      const rest = node.slice('tcp://'.length);
      const at = rest.lastIndexOf(':');
      pending = new Promise((resolve, reject) => {
        const socket = this.net.createConnection({host: rest.slice(0, at), port: Number(rest.slice(at + 1))});
        const timer = setTimeout(() => {
          socket.destroy();
          reject(new Unreachable(`cannot reach ${node}: no connection in time`));
        }, 5000);
        timer.unref?.();
        socket.once('connect', () => {
          clearTimeout(timer);
          this.sockets.add(socket);
          resolve(socket);
        });
        socket.on('error', (error) => {
          clearTimeout(timer);
          this.connections.delete(node);
          reject(new Unreachable(`cannot reach ${node}: ${error.message}`));
        });
        socket.on('close', () => this.connections.delete(node));
      });
      pending.catch(() => {});
      this.connections.set(node, pending);
    }
    return pending;
  }
  async send(node, frame) {
    const header = new Uint8Array(4);
    new DataView(header.buffer).setUint32(0, frame.length);
    const socket = await this.connect(node);
    socket.write(concatBytes(header, frame));
  }
  async close() {
    for (const socket of this.sockets) socket.destroy();
    await new Promise((resolve) => this.server.close(() => resolve()));
  }
}

/**
 * Frames as HTTP POST bodies to /lawspec; the address is http://host:port.
 * Create one with `await HttpTransport.listen(host, port)`.
 */
export class HttpTransport extends Transport {
  http;
  deliver;
  agent;
  server;
  static async listen(host = '127.0.0.1', port = 0) {
    const http = await import('node:http');
    const transport = new HttpTransport();
    transport.http = http;
    transport.deliver = null;
    transport.agent = new http.Agent({keepAlive: true});
    transport.server = http.createServer((request, response) => {
      const chunks = [];
      request.on('data', (chunk) => chunks.push(chunk));
      request.on('end', () => {
        const ok = request.method === 'POST' && request.url === '/lawspec';
        response.writeHead(ok ? 204 : 404);
        response.end();
        if (ok && transport.deliver !== null) transport.deliver(new Uint8Array(concatBytes(...chunks)));
      });
    });
    await new Promise((resolve, reject) => {
      transport.server.once('error', reject);
      transport.server.listen(port, host, resolve);
    });
    transport.address = `http://${host}:${transport.server.address().port}`;
    return transport;
  }
  start(deliver) {
    this.deliver = deliver;
  }
  send(node, frame) {
    return new Promise((resolve, reject) => {
      const request = this.http.request(node + '/lawspec', {
        method: 'POST', agent: this.agent, timeout: 5000,
        headers: {'Content-Type': 'application/octet-stream', 'Content-Length': frame.length},
      }, (response) => {
        response.resume();
        response.on('end', resolve);
      });
      request.on('timeout', () => request.destroy(new Error('no answer in time')));
      request.on('error', (error) => reject(new Unreachable(`cannot reach ${node}: ${error.message}`)));
      request.end(frame);
    });
  }
  async close() {
    this.agent.destroy();
    this.server.closeAllConnections?.();
    await new Promise((resolve) => this.server.close(() => resolve()));
  }
}

// The secure network handler (docs/reference/language/distribution.md,
// "Security"). Every node has an ML-DSA-65 identity (FIPS 204). Before two
// nodes exchange frames, the one that sends first runs a handshake: it sends
// a signed hello with a fresh ML-KEM-768 encapsulation key (FIPS 203), the
// other answers with a signed welcome carrying the ciphertext, and both derive
// an AES-256-GCM key (SP 800-38D) with SHAKE256 (FIPS 202). Frames then cross
// sealed. Records are bytes, so every transport carries them, and the format
// is the same on every target.
//
// ML-KEM and ML-DSA come from @noble/post-quantum, SHA3, SHAKE and AES-GCM
// from node:crypto, as lawspec.crypto's default handlers have them. They are
// loaded when the first secure node is made (loadNetworkCrypto), so programs
// without nodes do not need them.

const RECORD = Uint8Array.of(0x4C, 0x53, 0x01);
const HELLO = 1, WELCOME = 2, DATA = 3;
const LABEL_HELLO = UTF8.encode('lawspec-handshake-v1-hello');
const LABEL_WELCOME = UTF8.encode('lawspec-handshake-v1-welcome');
const LABEL_KEY = UTF8.encode('lawspec-session-v1');
const LABEL_FRAME = UTF8.encode('lawspec-frame-v1');
const HANDSHAKE_RETRY = 100;
const HANDSHAKE_DEADLINE = 5000;
const QUEUE_LIMIT = 4096;
const NO_CONTEXT = new Uint8Array(0);

let networkCryptoLoad = null;
let networkCryptoLoaded = null;

/**
 * Loads what a secure node needs: @noble/post-quantum (npm install
 * @noble/post-quantum@0.7.1) and node:crypto. A Node loads them itself;
 * await this before handshakeVector or a NodeIdentity's keys.
 */
export function loadNetworkCrypto() {
  if (networkCryptoLoad === null) {
    networkCryptoLoad = Promise.all([
      import('node:crypto'),
      import('@noble/post-quantum/ml-kem.js'),
      import('@noble/post-quantum/ml-dsa.js'),
    ]).then(([crypto, kem, dsa]) => {
      networkCryptoLoaded = {crypto, mlKem: kem.ml_kem768, mlDsa: dsa.ml_dsa65};
      return networkCryptoLoaded;
    }, (error) => {
      networkCryptoLoad = null;
      throw new Error('a secure node needs @noble/post-quantum: npm install @noble/post-quantum@0.7.1', {cause: error});
    });
  }
  return networkCryptoLoad;
}

function networkCrypto() {
  if (networkCryptoLoaded === null) throw new Error('the network cryptography is not loaded: await ls.loadNetworkCrypto() first');
  return networkCryptoLoaded;
}

const asBytes = (data) => (data instanceof Uint8Array && data.constructor === Uint8Array ? data : new Uint8Array(data));

function sha3(data) {
  return asBytes(networkCrypto().crypto.createHash('sha3-256').update(data).digest());
}

function shake(data, length) {
  return asBytes(networkCrypto().crypto.createHash('shake256', {outputLength: length}).update(data).digest());
}

function secureRandom(n) {
  const out = new Uint8Array(n);
  globalThis.crypto.getRandomValues(out);
  return out;
}

/**
 * A one-time token from the operating system's secure generator: 32 bytes
 * as 64 hexadecimal digits, as SecureRandom's secureToken gives.
 */
export function secureToken() {
  return hex(secureRandom(32));
}

function fromHex(text) {
  if (text.length % 2 !== 0 || /[^0-9a-fA-F]/.test(text)) throw new Error('not hexadecimal: ' + text);
  const out = new Uint8Array(text.length / 2);
  for (let i = 0; i < out.length; i++) out[i] = parseInt(text.slice(2 * i, 2 * i + 2), 16);
  return out;
}

function equalBytes(a, b) {
  if (a.length !== b.length) return false;
  let difference = 0;
  for (let i = 0; i < a.length; i++) difference |= a[i] ^ b[i];
  return difference === 0;
}

/** A record field: its length (LEB128), then its bytes. */
function w(data) {
  const out = [];
  putVarint(out, BigInt(data.length));
  return concatBytes(Uint8Array.from(out), data);
}

function readFields(data, pos, count) {
  const fields = [];
  for (let i = 0; i < count; i++) {
    let n;
    [n, pos] = getVarint(data, pos);
    if (BigInt(pos) + n > BigInt(data.length)) throw new WireError('a record field runs past its end');
    fields.push(data.slice(pos, pos + Number(n)));
    pos += Number(n);
  }
  return [fields, pos];
}

/** A node's long-term ML-DSA-65 identity, kept as its 32-byte seed. */
export class NodeIdentity {
  seed;
  #keys = null;
  constructor(seed) {
    const bytes = Uint8Array.from(seed);
    if (bytes.length !== 32) throw new Error('a node identity is a 32-byte ML-DSA-65 seed');
    this.seed = bytes;
  }
  #derived() {
    if (this.#keys === null) this.#keys = networkCrypto().mlDsa.keygen(this.seed.slice());
    return this.#keys;
  }
  static generate() {
    return new NodeIdentity(secureRandom(32));
  }
  /** The identity lawspec.json binds (lawspec-network.conf), or a fresh one. */
  static async configured() {
    await loadNetworkCrypto();
    const {identity} = await networkConfig();
    return identity ?? NodeIdentity.generate();
  }
  get verifyingKey() {
    return this.#derived().publicKey;
  }
  /** SHA3-256 of the verifying key, in hexadecimal. */
  get fingerprint() {
    return hex(sha3(this.verifyingKey));
  }
  sign(message) {
    return networkCrypto().mlDsa.sign(message, this.#derived().secretKey.slice(), {context: NO_CONTEXT});
  }
}

function verifySigned(verifyingKey, message, signature) {
  try {
    return networkCrypto().mlDsa.verify(signature, message, verifyingKey, {context: NO_CONTEXT}) === true;
  } catch {
    return false;
  }
}

/**
 * lawspec-network.conf, which the compiler writes from lawspec.json's
 * network binding: the file LAWSPEC_NETWORK_CONF names, or the first found
 * in the working directory and the directories above it. Lines `identity
 * <file>` (a hex seed) and `trusted <file>` (hex fingerprints, one per
 * line), relative to it; `#` begins a comment. Resolves to {identity,
 * trusted}, each null when not given.
 */
async function networkConfig() {
  const none = {identity: null, trusted: null};
  if (typeof process === 'undefined' || !process.versions?.node) return none;
  const fs = await import('node:fs/promises');
  const path = await import('node:path');
  const exists = async (file) => {
    try {
      await fs.access(file);
      return true;
    } catch {
      return false;
    }
  };
  let conf = process.env.LAWSPEC_NETWORK_CONF;
  if (conf === undefined) {
    let here = process.cwd();
    for (;;) {
      const candidate = path.join(here, 'lawspec-network.conf');
      if (await exists(candidate)) {
        conf = candidate;
        break;
      }
      const parent = path.dirname(here);
      if (parent === here) return none;
      here = parent;
    }
  }
  if (!(await exists(conf))) return none;
  const base = path.dirname(path.resolve(conf));
  let identity = null, trusted = null;
  for (const line of (await fs.readFile(conf, 'utf8')).split('\n')) {
    const trimmed = line.trim();
    const at = trimmed.search(/\s/);
    if (at < 0 || trimmed.startsWith('#')) continue;
    const word = trimmed.slice(0, at), target = path.join(base, trimmed.slice(at).trim());
    if (word === 'identity') {
      identity = new NodeIdentity(fromHex((await fs.readFile(target, 'utf8')).trim()));
    } else if (word === 'trusted') {
      trusted = new Set((await fs.readFile(target, 'utf8')).split(/\s+/).filter((t) => t !== '').map((t) => t.toLowerCase()));
    }
  }
  return {identity, trusted};
}

export function helloBody(session, address, verifyingKey, encapsulationKey) {
  return concatBytes(w(session), w(UTF8.encode(address)), w(verifyingKey), w(encapsulationKey));
}

export function welcomeBody(session, address, verifyingKey, ciphertext, hello) {
  return concatBytes(w(session), w(UTF8.encode(address)), w(verifyingKey), w(ciphertext), w(sha3(hello)));
}

/**
 * The AES-256-GCM key: SHAKE256(shared || label || SHA3(hello body) ||
 * SHA3(welcome body)), 32 bytes.
 */
export function sessionKey(shared, hello, welcome) {
  return shake(concatBytes(shared, LABEL_KEY, sha3(hello), sha3(welcome)), 32);
}

/** A data record: the frame sealed with key, under a fresh nonce unless one is given. */
export function sealFrame(key, session, direction, frame, nonce = secureRandom(12)) {
  const {crypto} = networkCrypto();
  const cipher = crypto.createCipheriv('aes-256-gcm', key, nonce);
  cipher.setAAD(concatBytes(LABEL_FRAME, session, Uint8Array.of(direction)));
  const body = concatBytes(cipher.update(frame), cipher.final(), cipher.getAuthTag());
  return concatBytes(RECORD, Uint8Array.of(DATA), w(session), Uint8Array.of(direction), w(concatBytes(nonce, body)));
}

/** The frame a data record seals, or null. */
export function openFrame(key, record) {
  record = asBytes(record);
  let session, direction, sealed, end;
  try {
    let pos;
    [[session], pos] = readFields(record, 4, 1);
    if (pos >= record.length) return null;
    direction = record[pos];
    [[sealed], end] = readFields(record, pos + 1, 1);
  } catch {
    return null;
  }
  if (end !== record.length || sealed.length < 28) return null;
  try {
    const {crypto} = networkCrypto();
    const decipher = crypto.createDecipheriv('aes-256-gcm', key, sealed.subarray(0, 12));
    decipher.setAAD(concatBytes(LABEL_FRAME, session, Uint8Array.of(direction)));
    decipher.setAuthTag(sealed.subarray(sealed.length - 16));
    return concatBytes(decipher.update(sealed.subarray(12, sealed.length - 16)), decipher.final());
  } catch {
    return null;
  }
}

/**
 * Checks a handshake vector (hex fields, the addresses as text): the
 * bodies' hashes, the session key and a sealed frame, as every target must
 * compute them. Needs the network cryptography loaded (loadNetworkCrypto).
 */
export function handshakeVector(initiatorSeed, responderSeed, kemSeed, session, initiator, responder,
                                ciphertext, nonce, frame, helloHash, welcomeHash, key, record) {
  const {mlKem} = networkCrypto();
  const x = fromHex;
  const first = new NodeIdentity(x(initiatorSeed)), second = new NodeIdentity(x(responderSeed));
  const kem = mlKem.keygen(x(kemSeed));
  const hello = helloBody(x(session), initiator, first.verifyingKey, kem.publicKey);
  const welcome = welcomeBody(x(session), responder, second.verifyingKey, x(ciphertext), hello);
  const derived = sessionKey(asBytes(mlKem.decapsulate(x(ciphertext), kem.secretKey)), hello, welcome);
  const sealed = sealFrame(derived, x(session), 0, x(frame), x(nonce));
  const opened = openFrame(derived, sealed);
  return hex(sha3(hello)) === helloHash && hex(sha3(welcome)) === welcomeHash &&
    hex(derived) === key && hex(sealed) === record && opened !== null && equalBytes(opened, x(frame));
}

class SecureSession {
  id;
  peer;
  key;
  direction;
  confirmed;
  constructor(id, peer, key, direction, confirmed) {
    this.id = id;
    this.peer = peer;
    this.key = key;
    // 0: this node began the handshake; 1: the peer did.
    this.direction = direction;
    // A session the peer began is used for sending once a frame has arrived
    // on it, so the peer surely holds its key.
    this.confirmed = confirmed;
  }
}

/** Handshakes, sessions and sealed frames for one node. */
class SecureLayer {
  node;
  identity;
  trusted;
  sessions;
  outbound;
  pending;
  welcomes;
  known;
  ready;
  constructor(node, identity, trusted) {
    this.node = node;
    this.identity = identity;
    this.trusted = null;
    // By session id (hexadecimal).
    this.sessions = new Map();
    // By peer address: the session this node began.
    this.outbound = new Map();
    this.pending = new Map();
    this.welcomes = new Map();
    // The identity first seen at each address: a later, different one is
    // refused (trust on first use, unless trusted names them).
    this.known = new Map();
    this.ready = this.prepare(identity, trusted);
    this.ready.catch(() => {});
  }
  async prepare(identity, trusted) {
    await loadNetworkCrypto();
    const config = identity === null || trusted === null ? await networkConfig() : null;
    this.identity = identity ?? config.identity ?? NodeIdentity.generate();
    const fingerprints = trusted ?? config.trusted;
    this.trusted = fingerprints === null ? null : new Set([...fingerprints].map((t) => String(t).toLowerCase()));
    // The verifying key, derived once now rather than at the first hello.
    void this.identity.verifyingKey;
    this.node.identity = this.identity;
  }
  close() {
    for (const pending of this.pending.values()) {
      pending.done = true;
      clearTimeout(pending.timer);
    }
    this.pending.clear();
  }
  acceptPeer(address, verifyingKey) {
    const fingerprint = hex(sha3(verifyingKey));
    if (this.trusted !== null && !this.trusted.has(fingerprint)) return false;
    if (!this.known.has(address)) this.known.set(address, fingerprint);
    return this.known.get(address) === fingerprint;
  }
  async send(peer, frame) {
    await this.ready;
    let session = this.outbound.get(peer);
    if (session === undefined) {
      for (const s of this.sessions.values()) {
        if (s.peer === peer && s.confirmed) {
          session = s;
          break;
        }
      }
    }
    if (session !== undefined) {
      await this.node.transport.send(peer, sealFrame(session.key, session.id, session.direction, frame));
      return;
    }
    let pending = this.pending.get(peer);
    const start = pending === undefined;
    if (start) {
      pending = this.begin(peer);
      this.pending.set(peer, pending);
    }
    if (pending.queue.length < QUEUE_LIMIT) pending.queue.push(frame);
    if (!start) return;
    try {
      await this.node.transport.send(peer, pending.hello);
    } catch (error) {
      if (this.pending.get(peer) === pending) this.pending.delete(peer);
      pending.done = true;
      throw error;
    }
    this.retry(peer, pending);
  }
  begin(peer) {
    const {mlKem} = networkCrypto();
    const session = secureRandom(16);
    const kem = mlKem.keygen(secureRandom(64));
    const body = helloBody(session, this.node.address, this.identity.verifyingKey, kem.publicKey);
    const signature = this.identity.sign(concatBytes(LABEL_HELLO, body));
    return {session, kem, body, queue: [], done: false, timer: undefined,
      hello: concatBytes(RECORD, Uint8Array.of(HELLO), body, w(signature))};
  }
  /** Sends the hello again every 100ms until welcomed, for up to 5s. */
  retry(peer, pending) {
    const giveUp = Date.now() + HANDSHAKE_DEADLINE;
    const tick = () => {
      if (pending.done) return;
      if (this.node.closed || Date.now() >= giveUp) {
        if (this.pending.get(peer) === pending) this.pending.delete(peer);
        pending.done = true;
        return;
      }
      this.node.transport.send(peer, pending.hello).catch(() => {});
      pending.timer = setTimeout(tick, HANDSHAKE_RETRY);
      pending.timer.unref?.();
    };
    if (pending.done) return;
    pending.timer = setTimeout(tick, HANDSHAKE_RETRY);
    pending.timer.unref?.();
  }
  /**
   * The frame a record carries, or null (a handshake record, or one that
   * fails to verify or open).
   */
  receive(record) {
    record = asBytes(record);
    if (record.length < 4 || !equalBytes(record.subarray(0, 3), RECORD)) return null;
    try {
      switch (record[3]) {
        case HELLO: this.hello(record); return null;
        case WELCOME: this.welcome(record); return null;
        case DATA: return this.data(record);
        default: return null;
      }
    } catch {
      return null;
    }
  }
  hello(record) {
    const [[session, address, verifyingKey, encapsulationKey], pos] = readFields(record, 4, 4);
    const [[signature], end] = readFields(record, pos, 1);
    if (end !== record.length) return;
    const body = record.slice(4, pos);
    const from = STRICT_UTF8.decode(address);
    const id = hex(session);
    let answered = this.welcomes.get(id);
    if (answered === undefined) {
      if (!verifySigned(verifyingKey, concatBytes(LABEL_HELLO, body), signature)) return;
      if (!this.acceptPeer(from, verifyingKey)) return;
      const {mlKem} = networkCrypto();
      const {cipherText, sharedSecret} = mlKem.encapsulate(encapsulationKey);
      const welcome = welcomeBody(session, this.node.address, this.identity.verifyingKey, cipherText, body);
      answered = [from, concatBytes(RECORD, Uint8Array.of(WELCOME), welcome,
        w(this.identity.sign(concatBytes(LABEL_WELCOME, welcome))))];
      this.welcomes.set(id, answered);
      this.sessions.set(id, new SecureSession(session, from, sessionKey(asBytes(sharedSecret), body, welcome), 1, false));
    }
    this.node.transport.send(answered[0], answered[1]).catch(() => {});
  }
  welcome(record) {
    const [[session, address, verifyingKey, ciphertext, helloHash], pos] = readFields(record, 4, 5);
    const [[signature], end] = readFields(record, pos, 1);
    if (end !== record.length) return;
    const from = STRICT_UTF8.decode(address);
    const pending = this.pending.get(from);
    if (pending === undefined || pending.done || !equalBytes(pending.session, session) ||
        !equalBytes(helloHash, sha3(pending.body))) return;
    const body = record.slice(4, pos);
    if (!verifySigned(verifyingKey, concatBytes(LABEL_WELCOME, body), signature)) return;
    if (!this.acceptPeer(from, verifyingKey)) return;
    const {mlKem} = networkCrypto();
    const key = sessionKey(asBytes(mlKem.decapsulate(ciphertext, pending.kem.secretKey.slice())), pending.body, body);
    const established = new SecureSession(session, from, key, 0, true);
    this.pending.delete(from);
    pending.done = true;
    clearTimeout(pending.timer);
    this.sessions.set(hex(session), established);
    this.outbound.set(from, established);
    for (const frame of pending.queue) {
      this.node.transport.send(from, sealFrame(key, session, 0, frame)).catch(() => {});
    }
  }
  data(record) {
    const [[session]] = readFields(record, 4, 1);
    const found = this.sessions.get(hex(session));
    if (found === undefined) return null;
    const frame = openFrame(found.key, record);
    if (frame !== null) found.confirmed = true;
    return frame;
  }
}

class ReplySlot {
  promise;
  resolve;
  constructor() {
    this.promise = new Promise((resolve) => { this.resolve = resolve; });
  }
}

/**
 * A process's presence on a network: it names local mailboxes, actors,
 * channel ends and definitions, so other nodes can reach them at
 * <node address>/<name>, and it sends to theirs.
 *
 * Order is kept within one channel; a mailbox or an actor call is best
 * effort: a lost call fails with Unreachable after its timeout.
 */
export class Node {
  transport;
  address;
  entities;
  pending;
  seen;
  ids;
  endpoints;
  identity;
  secure;
  closed;
  arrivals;
  /**
   * identity: a NodeIdentity (by default the one lawspec.json binds, or a
   * fresh one); trusted: the fingerprints of the only peers to talk to (by
   * default any peer, each address keeping the first identity it shows). A
   * transport made for tests only (InsecureMemoryTransport) skips the
   * handshake; no other transport can. The identity is set once the secure
   * layer is ready (await node.ready()).
   */
  constructor(transport, {identity = null, trusted = null} = {}) {
    this.transport = transport;
    this.address = transport.address;
    this.closed = false;
    this.identity = identity;
    this.secure = transport instanceof InsecureMemoryTransport ? null : new SecureLayer(this, identity, trusted);
    if (this.secure === null) this.identity = null;
    this.arrivals = Promise.resolve();
    this.entities = new Map();
    this.pending = new Map();
    // Requests already seen, by sender and id, with their reply once sent:
    // a request sent again (lost reply, duplicated frame) is answered again
    // without running twice.
    this.seen = new Map();
    this.ids = 0;
    this.endpoints = new Set();
    transport.start((record) => this.arrive(record));
  }
  /** Resolves to this node's identity (null without the handshake) once it can send. */
  async ready() {
    if (this.secure !== null) await this.secure.ready;
    return this.identity;
  }
  arrive(record) {
    if (this.secure === null) {
      this.deliver(record);
      return;
    }
    // In order of arrival, once the secure layer is ready.
    this.arrivals = this.arrivals.then(() => this.secure.ready).then(() => {
      const frame = this.secure.receive(record);
      if (frame !== null) this.deliver(frame);
    }).catch(() => {});
  }
  transmit(node, frame) {
    if (this.secure === null) return this.transport.send(node, frame);
    return this.secure.send(node, frame);
  }
  async close() {
    this.closed = true;
    if (this.secure !== null) this.secure.close();
    for (const endpoint of this.endpoints) endpoint.stop();
    await this.transport.close();
  }
  nextId() {
    return ++this.ids;
  }
  async send(address, kind, payload, ident = 0) {
    const [node, name] = splitAddress(address);
    await this.transmit(node, frameEncode(kind, name, this.address, ident, payload));
  }
  /** Passes a frame on to address unchanged, keeping its source. */
  forward(address, kind, source, ident, payload) {
    const [node, name] = splitAddress(address);
    this.quietly(this.transmit(node, frameEncode(kind, name, source, ident, payload)));
  }
  quietly(promise) {
    promise.catch(() => {});
  }
  register(name, entity) {
    if (!name || name.includes('/')) throw new Error(`${name} is not a name: use letters, digits and dashes`);
    if (this.entities.has(name)) throw new Error(`${name} is already registered on ${this.address}`);
    this.entities.set(name, entity);
    return `${this.address}/${name}`;
  }
  deliver(frame) {
    let kind, to, source, ident, payload;
    try {
      [kind, to, source, ident, payload] = frameDecode(frame);
    } catch {
      return;
    }
    ident = Number(ident);
    if (kind === 'reply') {
      const slot = this.pending.get(ident);
      if (slot !== undefined) {
        this.pending.delete(ident);
        slot.resolve(payload);
      }
      return;
    }
    const entity = this.entities.get(to);
    if (entity === undefined) {
      if (ident) this.reply(source, ident, 3, `nothing is registered as ${to} on ${this.address}`);
      return;
    }
    if (ident) {
      const key = `${source}|${ident}`;
      if (this.seen.has(key)) {
        const answer = this.seen.get(key);
        if (answer !== null) this.quietly(this.send(source + '/', 'reply', answer, ident));
        return;
      }
      this.seen.set(key, null);
      if (this.seen.size > 10000) for (const old of [...this.seen.keys()].slice(0, 5000)) this.seen.delete(old);
    }
    Promise.resolve().then(() => entity.onFrame(this, kind, source, ident, payload)).catch(() => {});
  }
  reply(source, ident, status, body) {
    const payload = concatBytes(Uint8Array.of(status), typeof body === 'string' ? UTF8.encode(body) : body);
    const key = `${source}|${ident}`;
    if (this.seen.has(key)) this.seen.set(key, payload);
    this.quietly(this.send(source + '/', 'reply', payload, ident));
  }
  /** Sends a request, again every 100ms until answered: [status, body]. */
  async request(address, kind, payload, timeout) {
    const ident = this.nextId();
    const slot = new ReplySlot();
    this.pending.set(ident, slot);
    const giveUp = Date.now() + timeout * 1000;
    let answered = null;
    slot.promise.then((p) => { answered = p; });
    for (;;) {
      this.quietly(this.send(address, kind, payload, ident));
      const wait = Math.max(0, Math.min(100, giveUp - Date.now()));
      await Promise.race([slot.promise, sleep(wait)]);
      if (answered !== null) return [answered[0], answered.slice(1)];
      if (Date.now() >= giveUp) {
        this.pending.delete(ident);
        throw new Unreachable(`${address} did not answer within ${timeout}s`);
      }
    }
  }

  /** A local Mailbox that other nodes send to at <address>/name. */
  mailbox(name, descriptor, values = NO_TYPES) {
    const box = new Mailbox();
    this.register(name, new MailEntity(box, values, descriptor));
    return box;
  }
  remoteMailbox(address, descriptor, values = NO_TYPES, timeout = 5) {
    return new RemoteMailbox(this, address, descriptor, values, timeout);
  }
  /**
   * Lets other nodes call actor at <address>/name. handlers maps a message
   * name to [handler(state, ...args) -> [reply, state], argument
   * descriptors, reply descriptor].
   */
  serve(name, actor, handlers, values = NO_TYPES) {
    return this.register(name, new ActorEntity(actor, handlers, values));
  }
  /** A proxy calling the actor at address; signatures maps a message name to [argument descriptors, reply descriptor]. */
  remoteActor(address, signatures, values = NO_TYPES, timeout = 5) {
    return new RemoteActor(this, address, signatures, values, timeout);
  }
  /** Lets other nodes evaluate definitions: table maps a content hash to [function, argument descriptors, result descriptor]. */
  serveDefinitions(table, values = NO_TYPES, name = 'definitions') {
    return this.register(name, new DefinitionEntity(table, values));
  }
  /** Evaluates the definition with this content hash on another node. */
  async evaluate(node, digest, args, argumentDescriptors, result, values = NO_TYPES, timeout = 5, name = 'definitions') {
    const out = [];
    wirePut(NO_TYPES, D_TEXT, digest, out);
    argumentDescriptors.forEach((d, i) => wirePut(values, d, args[i], out));
    const [status, body] = await this.request(`${node}/${name}`, 'eval', Uint8Array.from(out), timeout);
    return replyValue(status, body, values, result);
  }
  /**
   * The first end of a channel named name here; its other end is dial(...)ed
   * from any node. steps: [sends, descriptor] per step, from this end's side.
   */
  listen(name, steps, values = NO_TYPES, deadline = 5) {
    const endpoint = new NetEndpoint(this, steps, values, 0, deadline);
    endpoint.address = this.register(name, endpoint);
    return endpoint;
  }
  /** The second end of the channel listening at address; steps are from this end's side. */
  dial(address, steps, values = NO_TYPES, deadline = 5) {
    const endpoint = new NetEndpoint(this, steps, values, 1, deadline);
    endpoint.address = this.register(`end-${this.nextId()}`, endpoint);
    endpoint.connect(address);
    return endpoint;
  }
  /**
   * Takes over a channel end another node moves here: address is <old
   * address>?take=<token>, as that node offered it. Resolves once the end's
   * state has arrived and its peer has been told (or after the deadline; the
   * old node then forwards to the end).
   */
  async take(address, steps, values = NO_TYPES, deadline = 5) {
    const endpoint = new NetEndpoint(this, steps, values, 0, deadline);
    endpoint.address = this.register(`end-${this.nextId()}`, endpoint);
    await endpoint.takeOver(address);
    return endpoint;
  }
}

function replyValue(status, body, values, d) {
  if (status === 0) return wireDecode(values, d, body);
  const message = new TextDecoder().decode(body);
  if (status === 1) {
    const error = new ActorCrashed(message);
    error.message = message;
    throw error;
  }
  if (status === 2) throw new ActorStopped(message);
  throw new Unreachable(message);
}

class MailEntity {
  box;
  values;
  descriptor;
  constructor(box, values, descriptor) {
    this.box = box;
    this.values = values;
    this.descriptor = descriptor;
  }
  onFrame(node, kind, source, ident, payload) {
    if (kind !== 'mail') return;
    let status = 0, body = new Uint8Array(0);
    try {
      this.box.send(wireDecode(this.values, this.descriptor, payload));
    } catch (error) {
      if (error instanceof ActorStopped) [status, body] = [2, error.message];
      else [status, body] = [3, `not a message of this mailbox: ${error.message}`];
    }
    if (ident) node.reply(source, ident, status, body);
  }
}

/**
 * Sends to a mailbox on another node. A send resolves once the mailbox has
 * the message (a lost one is sent again; the mailbox takes it once), and
 * rejects with Unreachable after the timeout, or ActorStopped if closed.
 */
export class RemoteMailbox {
  node;
  address;
  descriptor;
  values;
  timeout;
  constructor(node, address, descriptor, values, timeout = 5) {
    this.node = node;
    this.address = address;
    this.descriptor = descriptor;
    this.values = values;
    this.timeout = timeout;
  }
  async send(value) {
    const [status, body] = await this.node.request(this.address, 'mail', wireEncode(this.values, this.descriptor, value), this.timeout);
    if (status !== 0) replyValue(status, body, this.values, ['unit']);
  }
}

class ActorEntity {
  actor;
  handlers;
  values;
  constructor(actor, handlers, values) {
    this.actor = actor;
    this.handlers = handlers;
    this.values = values;
  }
  async onFrame(node, kind, source, ident, payload) {
    if (kind !== 'call') return;
    let handler, reply, args;
    try {
      let message, pos;
      [message, pos] = wireGet(NO_TYPES, D_TEXT, payload, 0);
      const entry = this.handlers[message];
      if (entry === undefined) throw new WireError(`no message ${message}`);
      let argumentDescriptors;
      [handler, argumentDescriptors, reply] = entry;
      args = argumentDescriptors.map((d) => {
        let v;
        [v, pos] = wireGet(this.values, d, payload, pos);
        return v;
      });
      if (pos !== payload.length) throw new WireError('extra bytes after the arguments');
    } catch (error) {
      node.reply(source, ident, 3, `not a message this actor handles: ${error.message}`);
      return;
    }
    try {
      const result = await this.actor.call((s) => handler(s, ...args));
      node.reply(source, ident, 0, wireEncode(this.values, reply, result));
    } catch (error) {
      if (error instanceof ActorStopped) node.reply(source, ident, 2, error.message);
      else node.reply(source, ident, 1, error.message);
    }
  }
}

/**
 * Calls an actor on another node: call(message, ...args) sends the message
 * and resolves to the reply, rejecting with Unreachable after the timeout,
 * or with what the actor's call threw (ActorCrashed, ActorStopped).
 */
export class RemoteActor {
  node;
  address;
  signatures;
  values;
  timeout;
  constructor(node, address, signatures, values, timeout) {
    this.node = node;
    this.address = address;
    this.signatures = signatures;
    this.values = values;
    this.timeout = timeout;
  }
  async call(message, ...args) {
    const [argumentDescriptors, reply] = this.signatures[message];
    const out = [];
    wirePut(NO_TYPES, D_TEXT, message, out);
    argumentDescriptors.forEach((d, i) => wirePut(this.values, d, args[i], out));
    const [status, body] = await this.node.request(this.address, 'call', Uint8Array.from(out), this.timeout);
    return replyValue(status, body, this.values, reply);
  }
}

class DefinitionEntity {
  table;
  values;
  constructor(table, values) {
    this.table = table;
    this.values = values;
  }
  async onFrame(node, kind, source, ident, payload) {
    if (kind !== 'eval') return;
    let fn, result, args;
    try {
      let digest, pos;
      [digest, pos] = wireGet(NO_TYPES, D_TEXT, payload, 0);
      const entry = this.table[digest];
      if (entry === undefined) throw new WireError('unknown hash');
      let argumentDescriptors;
      [fn, argumentDescriptors, result] = entry;
      args = argumentDescriptors.map((d) => {
        let v;
        [v, pos] = wireGet(this.values, d, payload, pos);
        return v;
      });
    } catch {
      node.reply(source, ident, 3, 'this node has no definition with that content hash');
      return;
    }
    try {
      node.reply(source, ident, 0, wireEncode(this.values, result, await fn(...args)));
    } catch (error) {
      node.reply(source, ident, 1, `${errorName(error)}: ${errorMessage(error)}`);
    }
  }
}

const NET_ABANDONED = Symbol('the other end gave up');
const D_BYTES = ['bytes'];

function putTexts(out, texts) {
  putVarint(out, BigInt(texts.length));
  for (const t of texts) wirePut(NO_TYPES, D_TEXT, t, out);
}

function getTexts(buf, pos) {
  let count;
  [count, pos] = getVarint(buf, pos);
  const texts = [];
  for (let i = 0n; i < count; i++) {
    let t;
    [t, pos] = wireGet(NO_TYPES, D_TEXT, buf, pos);
    texts.push(t);
  }
  return [texts, pos];
}

function putNumbered(out, items) {
  putVarint(out, BigInt(items.length));
  for (const [seq, body] of items) {
    wirePut(NO_TYPES, D_SEQ, seq, out);
    wirePut(NO_TYPES, D_BYTES, body, out);
  }
}

function getNumbered(buf, pos) {
  let count;
  [count, pos] = getVarint(buf, pos);
  const items = [];
  for (let i = 0n; i < count; i++) {
    let seq, body;
    [seq, pos] = wireGet(NO_TYPES, D_SEQ, buf, pos);
    [body, pos] = wireGet(NO_TYPES, D_BYTES, buf, pos);
    items.push([seq, Uint8Array.from(body)]);
  }
  return [items, pos];
}

const bySeq = (x, y) => (x[0] < y[0] ? -1 : x[0] > y[0] ? 1 : 0);

/**
 * One end of a channel between nodes, with the channel interface
 * (send(side, value), receive(side)). Each value travels in a numbered frame
 * that is sent again until acknowledged, so loss, duplication and
 * reordering are repaired; a peer silent for deadline seconds is treated as
 * failed (PeerFailed). Order is kept within the channel.
 *
 * An unused end can move to another node: offer() gives the address the new
 * node takes it over from (<address>?take=<token>). On a take frame with
 * that token, this end hands its state over (a state frame) and from then on
 * forwards every frame it gets to the new end; the new end tells the peer (a
 * moved frame) so the peer sends to it directly.
 */
class NetEndpoint {
  node;
  steps;
  values;
  side;
  deadline;
  address;
  peer;
  out;
  unacked;
  expected;
  early;
  inbox;
  step;
  gone;
  failure;
  timer;
  // Moving: the addresses this end had before (oldest first), the token a
  // taker must show, where the end went and the state frame it was given,
  // and, on the new node, the takeover in progress.
  history;
  token;
  movedTo;
  state;
  taking;
  taken;
  announcing;
  announcedAt;
  confirmed;
  constructor(node, steps, values, side, deadline) {
    this.node = node;
    this.steps = steps;
    this.values = values;
    this.side = side;
    this.deadline = deadline * 1000;
    this.address = null;
    this.peer = null;
    this.out = 0n;
    this.unacked = new Map();
    this.expected = 0n;
    this.early = new Map();
    this.inbox = new AsyncQueue();
    this.step = 0;
    this.gone = false;
    this.failure = null;
    this.history = [];
    this.token = null;
    this.movedTo = null;
    this.state = null;
    this.taking = null;
    this.taken = new Signal();
    this.announcing = false;
    this.announcedAt = 0;
    this.confirmed = new Signal();
    node.endpoints.add(this);
    this.timer = setInterval(() => this.resend(), 20);
    this.timer.unref?.();
  }
  stop() {
    clearInterval(this.timer);
  }
  connect(address) {
    this.peer = address;
    this.transmit(-1n, UTF8.encode('hello'));
  }
  frame(seq, body) {
    const head = [];
    wirePut(NO_TYPES, D_SEQ, seq, head);
    wirePut(NO_TYPES, D_TEXT, this.address, head);
    return concatBytes(Uint8Array.from(head), body);
  }
  transmit(seq, body) {
    const payload = this.frame(seq, body);
    const now = Date.now();
    this.unacked.set(seq, [payload, now, now, body]);
    if (this.peer !== null) this.node.quietly(this.node.send(this.peer, 'chan', payload));
  }
  resend() {
    if (this.gone || this.movedTo !== null) {
      this.stop();
      return;
    }
    if (this.taking !== null && !this.taken.done) return;
    const now = Date.now();
    const due = [...this.unacked.values()].filter((entry) => now - entry[2] > 50);
    if (due.some((entry) => now - entry[1] > this.deadline)) {
      this.fail('the other end did not answer in time (unreachable)');
      return;
    }
    if (this.peer === null) return;
    if (this.announcing && !this.confirmed.done && now - this.announcedAt > 50) {
      this.announcedAt = now;
      const moved = [];
      putTexts(moved, this.history);
      wirePut(NO_TYPES, D_TEXT, this.address, moved);
      this.node.quietly(this.node.send(this.peer, 'moved', Uint8Array.from(moved)));
    }
    for (const entry of due) {
      entry[2] = now;
      this.node.quietly(this.node.send(this.peer, 'chan', entry[0]));
    }
  }
  fail(reason) {
    if (this.gone) return;
    this.gone = true;
    this.failure = reason;
    this.unacked.clear();
    this.stop();
    this.inbox.put([NET_ABANDONED, reason]);
  }
  onFrame(node, kind, source, ident, payload) {
    if (kind === 'take') {
      this.give(payload);
      return;
    }
    if (this.movedTo !== null) {
      node.forward(this.movedTo, kind, source, ident, payload);
      return;
    }
    if (this.taking !== null && !this.taken.done) {
      // Until the state arrives, frames are dropped: their senders send them again.
      if (kind === 'state') this.install(payload);
      return;
    }
    if (kind === 'ack') {
      const [seq] = wireGet(NO_TYPES, D_SEQ, payload, 0);
      this.unacked.delete(seq);
      return;
    }
    if (kind === 'moved') {
      this.peerMoved(payload);
      return;
    }
    if (kind === 'moved-ack') {
      const [to] = wireGet(NO_TYPES, D_TEXT, payload, 0);
      if (to === this.address) this.confirmed.set();
      return;
    }
    if (kind !== 'chan') return;
    let seq, sender, pos;
    [seq, pos] = wireGet(NO_TYPES, D_SEQ, payload, 0);
    [sender, pos] = wireGet(NO_TYPES, D_TEXT, payload, pos);
    const body = payload.slice(pos);
    const ack = [];
    wirePut(NO_TYPES, D_SEQ, seq, ack);
    node.quietly(node.send(sender, 'ack', Uint8Array.from(ack)));
    if (seq === -1n) {
      if (this.peer === null) this.peer = sender;
      return;
    }
    if (seq < this.expected || this.early.has(seq)) return;
    this.early.set(seq, body);
    while (this.early.has(this.expected)) {
      this.inbox.put([null, this.early.get(this.expected)]);
      this.early.delete(this.expected);
      this.expected += 1n;
    }
  }
  /** The address another node takes this unused end over from. */
  offer() {
    if (this.token === null) this.token = secureToken();
    return `${this.address}?take=${this.token}`;
  }
  /**
   * A take frame: hands the state over once, to the first taker with the
   * token, and answers that taker's repeats with the same state.
   */
  give(payload) {
    let token, taker, pos;
    try {
      [token, pos] = wireGet(NO_TYPES, D_TEXT, payload, 0);
      [taker, pos] = wireGet(NO_TYPES, D_TEXT, payload, pos);
    } catch {
      return;
    }
    if (this.token === null || token !== this.token) return;
    if (this.movedTo === null) {
      const received = this.inbox.items.filter(([marker]) => marker === null).map(([, body]) => body);
      const state = [];
      wirePut(NO_TYPES, D_TEXT, token, state);
      wirePut(NO_TYPES, D_TEXT, this.failure ?? '', state);
      wirePut(NO_TYPES, D_TEXT, this.peer ?? '', state);
      putTexts(state, [...this.history, this.address]);
      wirePut(NO_TYPES, D_SEQ, this.out, state);
      wirePut(NO_TYPES, D_SEQ, this.expected, state);
      putNumbered(state, [...this.unacked].map(([seq, entry]) => [seq, entry[3]]).sort(bySeq));
      putNumbered(state, [...this.early].sort(bySeq));
      putVarint(state, BigInt(received.length));
      for (const body of received) wirePut(NO_TYPES, D_BYTES, body, state);
      this.movedTo = taker;
      this.state = Uint8Array.from(state);
      this.unacked.clear();
      this.early.clear();
      this.stop();
    } else if (this.movedTo !== taker) {
      return;
    }
    this.node.quietly(this.node.send(taker, 'state', this.state));
  }
  /**
   * Takes over the end offered at address (<old address>?take=<token>):
   * asks for its state until it comes, then tells the peer where the end is
   * now. Resolves once the peer knows, or after the deadline (the old node
   * then keeps forwarding to this end, as a relay would).
   */
  async takeOver(address) {
    const at = address.indexOf('?');
    const old = address.slice(0, at), token = address.slice(at + 1).slice('take='.length);
    this.taking = [old, token];
    const request = [];
    wirePut(NO_TYPES, D_TEXT, token, request);
    wirePut(NO_TYPES, D_TEXT, this.address, request);
    const giveUp = Date.now() + this.deadline;
    while (!this.taken.done) {
      this.node.quietly(this.node.send(old, 'take', Uint8Array.from(request)));
      await Promise.race([this.taken.promise, sleep(50)]);
      if (this.taken.done) break;
      if (Date.now() >= giveUp) {
        this.taking = null;
        this.fail('the node the end came from did not hand it over in time (unreachable)');
        return;
      }
    }
    const left = giveUp - Date.now();
    if (left > 0) await Promise.race([this.confirmed.promise, sleep(left)]);
  }
  install(payload) {
    let token, failure, peer, history, out, expected, unacked, early, count, pos;
    const received = [];
    try {
      [token, pos] = wireGet(NO_TYPES, D_TEXT, payload, 0);
      [failure, pos] = wireGet(NO_TYPES, D_TEXT, payload, pos);
      [peer, pos] = wireGet(NO_TYPES, D_TEXT, payload, pos);
      [history, pos] = getTexts(payload, pos);
      [out, pos] = wireGet(NO_TYPES, D_SEQ, payload, pos);
      [expected, pos] = wireGet(NO_TYPES, D_SEQ, payload, pos);
      [unacked, pos] = getNumbered(payload, pos);
      [early, pos] = getNumbered(payload, pos);
      [count, pos] = getVarint(payload, pos);
      for (let i = 0n; i < count; i++) {
        let body;
        [body, pos] = wireGet(NO_TYPES, D_BYTES, payload, pos);
        received.push(Uint8Array.from(body));
      }
    } catch {
      return;
    }
    if (this.taking === null || token !== this.taking[1] || this.taken.done) return;
    const now = Date.now();
    this.peer = peer === '' ? null : peer;
    this.history = history;
    this.out = out;
    this.expected = expected;
    // Sent again from here at once, under this end's address.
    this.unacked = new Map(unacked.map(([seq, body]) => [seq, [this.frame(seq, body), now, 0, body]]));
    this.early = new Map(early);
    for (const body of received) this.inbox.put([null, body]);
    this.announcing = true;
    this.taken.set();
    if (failure !== '') this.fail(failure);
  }
  /** The peer moved: from now on send to its new address. */
  peerMoved(payload) {
    let history, to, pos;
    try {
      [history, pos] = getTexts(payload, 0);
      [to, pos] = wireGet(NO_TYPES, D_TEXT, payload, pos);
    } catch {
      return;
    }
    if (this.peer === null || history.includes(this.peer)) this.peer = to;
    if (this.peer === to) {
      const answer = [];
      wirePut(NO_TYPES, D_TEXT, to, answer);
      this.node.quietly(this.node.send(to, 'moved-ack', Uint8Array.from(answer)));
    }
  }
  stepDescriptor(sends) {
    if (this.step >= this.steps.length) throw new Error("this channel's protocol has ended");
    const [stepSends, d] = this.steps[this.step];
    if (Boolean(stepSends) !== sends) throw new Error('this step ' + (stepSends ? 'sends' : 'receives'));
    this.step += 1;
    return d;
  }
  send(side, value) {
    if (this.gone) throw new PeerFailed('the other end has failed');
    const d = this.stepDescriptor(true);
    const body = [0];
    wirePut(this.values, d, value, body);
    const seq = this.out;
    this.out += 1n;
    this.transmit(seq, Uint8Array.from(body));
  }
  /** Resolves to the next value; rejects with PeerFailed, or a timeout error after timeout ms. */
  async receive(side, timeout = undefined) {
    const d = this.stepDescriptor(false);
    const got = await this.inbox.get(timeout === undefined ? 2 ** 31 - 1 : timeout);
    if (got === TIMED_OUT_RECEIVE) throw new Error('no message arrived in time');
    const [marker, body] = got;
    if (marker === NET_ABANDONED) {
      this.inbox.items.unshift(got);
      throw new PeerFailed(body);
    }
    if (body[0] === 1) {
      this.fail('the other end gave up the conversation');
      throw new PeerFailed();
    }
    return wireDecode(this.values, d, body.slice(1));
  }
  receiveNow() {
    throw new Error('a channel between nodes has no immediate receive; await receive() instead');
  }
  /** Gives up: the other end's receives fail after what was sent. */
  abandon(side) {
    const seq = this.out;
    this.out += 1n;
    this.transmit(seq, Uint8Array.of(1));
  }
}

/** A one-time event: set() resolves promise; done says whether it has. */
class Signal {
  done = false;
  promise;
  resolve;
  constructor() {
    this.promise = new Promise((resolve) => { this.resolve = resolve; });
  }
  set() {
    this.done = true;
    this.resolve();
  }
}

const NUMBER_INTEGERS = new Set(['Int8', 'Int16', 'Int32', 'UInt8', 'UInt16', 'UInt32', 'CodePoint', 'CodeUnit16']);

/**
 * A logical scalar as its native value: integers of 32 bits or fewer are
 * numbers in JavaScript, wider ones bigints. Other values are unchanged.
 */
export function nativeScalar(d, value) {
  return d !== undefined && d[0] === 'int' && typeof value === 'bigint' && NUMBER_INTEGERS.has(String(d[1]))
    ? Number(value) : value;
}

/**
 * A network channel end seen through native values: each step's value is
 * converted with the schema (references null are scalars, converted by
 * nativeScalar).
 */
/**
 * A step that sends another protocol's first end: start() is that end's
 * start class, and wire() that protocol's [steps, parts] from it.
 */
export class EndPart {
  start;
  wire;
  constructor(start, wire) {
    this.start = start;
    this.wire = wire;
  }
}

/**
 * A network channel end seen through native values: each step's part
 * converts its value with the schema (null needs no conversion), or, for an
 * EndPart, sends a channel end and receives one. A network end moves to the
 * receiving node (the value is <address>?take=<token>); a local end stays
 * here behind a relay (the value is the relay's address).
 */
export class NativeChannel {
  endpoint;
  references;
  schema;
  step;
  address;
  constructor(endpoint, references, schema = null) {
    this.endpoint = endpoint;
    this.references = references;
    this.schema = schema;
    this.step = 0;
    this.address = endpoint.address;
  }
  reference() {
    const reference = this.step < this.references.length ? this.references[this.step] : null;
    this.step += 1;
    return reference;
  }
  send(side, value) {
    const reference = this.reference();
    if (reference instanceof EndPart) {
      this.endpoint.send(side, offerEnd(this.endpoint.node, this.endpoint.values, value, reference, this.schema));
      return;
    }
    this.endpoint.send(side, reference === null ? value : this.schema.fromNative(reference, value));
  }
  async receive(side) {
    const reference = this.reference();
    const value = await this.endpoint.receive(side);
    if (reference instanceof EndPart) {
      const [steps, parts] = reference.wire();
      const node = this.endpoint.node;
      const endpoint = value.includes('?take=')
        ? await node.take(value, steps, this.endpoint.values)
        : node.dial(value, steps, this.endpoint.values);
      const Start = reference.start();
      return new Start(new NativeChannel(endpoint, parts, this.schema), 0);
    }
    if (reference !== null) return this.schema.toNative(reference, value);
    return nativeScalar(this.endpoint.steps[this.endpoint.step - 1]?.[1], value);
  }
  receiveNow() {
    return this.endpoint.receiveNow();
  }
  abandon(side) {
    this.endpoint.abandon(side);
  }
}

/**
 * The text that gives an unused channel end to another node. An end that is
 * itself between nodes moves there; a local end stays here and a relay on
 * node carries its conversation.
 */
function offerEnd(node, values, end, part, schema) {
  const [channel, side] = end.use();
  if (channel instanceof NativeChannel && channel.step === 0) return channel.endpoint.offer();
  return relayEnd(node, values, channel, side, part, schema);
}

/**
 * Offers a local channel end to another node: a relay on node listens for
 * the receiver and passes each step between it and the end, which stays
 * here. Returns the relay's address. A failure on either side gives up the
 * other.
 */
function relayEnd(node, values, channel, side, part, schema) {
  const [steps, parts] = part.wire();
  const relay = node.listen(`relay-${node.nextId()}`, steps.map(([s, d]) => [!s, d]), values);
  const relayed = new NativeChannel(relay, parts, schema);
  (async () => {
    try {
      for (const [sends] of steps) {
        if (sends) channel.send(side, await relayed.receive(0));
        else relayed.send(0, await channel.receive(side));
      }
    } catch {
      for (const giveUp of [() => channel.abandon(side), () => relay.abandon(0)]) {
        try {
          giveUp();
        } catch {
          // already failed
        }
      }
    }
  })();
  return relay.address;
}
