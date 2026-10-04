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
export function equal(a, b, ta, tb) {
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

/** Make the default runtime virtual, as generated tests do. */
export function useVirtualClock(seed = 0n) {
  defaultRuntime = new WorkflowRuntime(new VirtualClock(), seed, false);
}

export function workflowRuntime(symbols) {
  const runtime = symbols instanceof Map ? symbols.get(WORKFLOW) : undefined;
  if (runtime !== undefined) return runtime;
  if (defaultRuntime === null) defaultRuntime = new WorkflowRuntime();
  return defaultRuntime;
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
    const result = attempt();
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

/** A RetryDecision's delay in microseconds, or null to stop. */
export function retryDecision(decision) {
  if (decision.tag !== 'lawspec.time::type::RetryDecision::RetryAfter') return null;
  return decision.fields[0].fields[0];
}

// Asynchronous workflows: the same, with stages that await their steps. A
// stage's timeout races each attempt against a timer (real time; the
// runtime generated tests install has timeouts off, as its gates are).

async function sleepFor(clock, delay) {
  await clock.sleepAsync(delay);
}

const TIMED_OUT = Symbol('timed out');

async function timed(runtime, policy, attempt, control) {
  if (policy.timeout === null || policy.timeout <= 0n || !runtime.gates) return attempt();
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
 * wins; when every attempt fails, the last failure. Off where gates are.
 */
function hedged(runtime, policy, attempt, control) {
  if (policy.hedge === null || !runtime.gates) return attempt();
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

class ModelCommand {
  name;
  arguments;
  state;
  unit;
  needs;
  shifts;
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
    const command = model.commands[index];
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

async function generateRun(model, random, length, size) {
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
    const index = allowed[Number(random.below(BigInt(allowed.length)))];
    const command = model.commands[index];
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
      const command = model.commands[index];
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
    const command = model.commands[index];
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
    ...steps.map(([i, args]) => model.commands[i].name + '(' + args.map(render).join(', ') + ')')];
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
    let run = await generateRun(model, random, length, 1 + c % 8);
    const failure = await execute(model, run);
    if (failure !== null) {
      let step, message;
      [run, [step, message]] = await shrinkRun(model, run, failure, maxShrinks);
      throw new Error(`model ${model.name} fails at step ${step} of ${describeRun(model, run)}: ${message}`);
    }
  }
}

// Parallel runs of a shared model. A case is a sequential prefix and two
// branches, generated so that the model allows every interleaving of the
// branches. The system runs the branches at the same time, as concurrent
// async calls that interleave where they await, recording when each call
// starts and returns; the history must be linearizable: some interleaving
// that keeps every call after those that returned before it started must
// give every result the model gives, and leave the state the model leaves.
// A race breaks this for some schedules, so each case runs several times.

/** Every merge of two sequences of branch steps, a first. */
function* interleavings(a, b) {
  if (!a.length) {
    yield [...b];
    return;
  }
  if (!b.length) {
    yield [...a];
    return;
  }
  for (const rest of interleavings(a.slice(1), b)) yield [a[0], ...rest];
  for (const rest of interleavings(a, b.slice(1))) yield [b[0], ...rest];
}

const branchSteps = (branches) => branches.map((b, i) => b.map((_, k) => [i, k]));

/** Whether the model allows the prefix then every interleaving. */
async function parallelAllowed(model, prefix, branches) {
  const symbols = new Map();
  let states;
  try {
    states = await simulate(model, symbols, prefix);
  } catch (error) {
    if (error instanceof Invalid) return false;
    throw error;
  }
  for (const order of interleavings(...branchSteps(branches))) {
    let state = states[states.length - 1];
    try {
      for (const [i, k] of order) {
        const [index, args] = branches[i][k];
        [state] = await stepModel(model.commands[index], symbols, args, state);
      }
    } catch (error) {
      if (error instanceof Invalid) return false;
      throw error;
    }
  }
  return true;
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

async function generateParallel(model, random, size) {
  const prefix = await generateRun(model, random, Number(random.below(4n)), size);
  let state;
  try {
    const states = await simulate(model, new Map(), prefix);
    state = states[states.length - 1];
  } catch (error) {
    if (error instanceof Invalid) return [prefix, [[], []]];
    throw error;
  }
  const branches = [];
  for (let b = 0; b < 2; b++)
    branches.push(await generateBranch(model, random, state, 1 + Number(random.below(4n)), size));
  // Drop the last steps until every interleaving is allowed.
  while (!(await parallelAllowed(model, prefix, branches))) {
    const longest = branches[0].length >= branches[1].length ? 0 : 1;
    branches[longest] = branches[longest].slice(0, -1);
  }
  return [prefix, branches];
}

/** null when the history is linearizable; otherwise what went wrong. */
async function executeParallel(model, testCase) {
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
    for (let k = 0; k < branches[i].length; k++) {
      const [index, args] = branches[i][k];
      const command = model.commands[index];
      const full = [...args];
      full.splice(command.state, 0, state);
      const called = tick();
      let result;
      try {
        result = await command.run(own, ...full);
      } catch (error) {
        errors.push(`${command.name} raised ${errorName(error)}: ${errorMessage(error)}`);
        result = null;
      }
      history[i][k] = [called, tick(), result];
    }
  };
  await Promise.all(branches.map((_, i) => branch(i)));
  if (errors.length) return errors[0];
  const states = await simulate(model, symbols, prefix);
  const expected = states[states.length - 1];
  const final = model.abstract !== null ? await model.abstract(symbols, state) : null;
  for (const order of interleavings(...branchSteps(branches))) {
    if (!respectsTime(order, history)) continue;
    if (await linearizes(model, symbols, branches, history, order, expected, final, state)) return null;
  }
  const observed = [];
  branches.forEach((b, i) => b.forEach(([index], k) =>
    observed.push(`${'AB'[i]}: ${model.commands[index].name}() returned ${render(history[i][k][2])}`)));
  return `no order of the parallel calls agrees with the model (${observed.join('; ')})`;
}

/** No call is placed before one that returned before it started. */
function respectsTime(order, history) {
  for (let x = 0; x < order.length; x++)
    for (let y = x + 1; y < order.length; y++) {
      const [i, k] = order[x], [j, l] = order[y];
      if (history[j][l][1] < history[i][k][0]) return false;
    }
  return true;
}

async function linearizes(model, symbols, branches, history, order, expected, final, state) {
  try {
    for (const [i, k] of order) {
      const [index, args] = branches[i][k];
      const command = model.commands[index];
      let wanted;
      [expected, wanted] = await stepModel(command, symbols, args, expected);
      if (!command.unit && compareValues(history[i][k][2], wanted) !== 0) return false;
    }
  } catch (error) {
    if (error instanceof Invalid) return false;
    throw error;
  }
  if (final !== null && compareValues(final, expected) !== 0) return false;
  for (const [kind, invariant] of model.invariants)
    if (!(await invariant(symbols, kind === 'model' ? expected : state))) return false;
  return true;
}

async function parallelFails(model, testCase, repeats) {
  for (let r = 0; r < repeats; r++) {
    const failure = await executeParallel(model, testCase);
    if (failure !== null) return failure;
  }
  return null;
}

async function shrinkParallel(model, testCase, failure, repeats, budget) {
  while (budget > 0) {
    const [prefix, branches] = testCase;
    const [startArgs, steps] = prefix;
    const candidates = [];
    for (let k = 0; k < steps.length; k++)
      candidates.push([[startArgs, [...steps.slice(0, k), ...steps.slice(k + 1)]], branches]);
    for (let i = 0; i < branches.length; i++)
      for (let k = 0; k < branches[i].length; k++)
        candidates.push([prefix, branches.map((b, j) => (j !== i ? b : [...b.slice(0, k), ...b.slice(k + 1)]))]);
    let improved = false;
    for (const candidate of candidates) {
      budget -= 1;
      if (budget <= 0) {
        improved = true; // stops like Python's break out of for-else
        break;
      }
      if (!(await parallelAllowed(model, ...candidate))) continue;
      const found = await parallelFails(model, candidate, repeats);
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
  return `${describeRun(model, prefix)}, then A: ${describe(branches[0]) || 'nothing'} and B: ` +
    `${describe(branches[1]) || 'nothing'} at the same time`;
}

/**
 * Checks a shared model's histories under concurrency; a failure throws an
 * Error naming the smallest failing case found.
 */
export async function checkModelParallelAsync(model, options = {}) {
  const {cases = 50, repeats = 20, maxShrinks = 200} = options;
  let seed = options.seed;
  if (seed === undefined || seed === null) seed = BigInt(globalThis.process?.env?.LAWSPEC_SEED ?? '0');
  const random = new SplitMix64(BigInt(seed) ^ 0x5BD1E995n);
  for (let c = 0; c < cases; c++) {
    let testCase = await generateParallel(model, random, 1 + c % 8);
    let failure = await parallelFails(model, testCase, repeats);
    if (failure !== null) {
      [testCase, failure] = await shrinkParallel(model, testCase, failure, Math.max(2, Math.floor(repeats / 2)), maxShrinks);
      throw new Error(`model ${model.name} is not linearizable: ${describeParallel(model, testCase)}: ${failure}`);
    }
  }
}
