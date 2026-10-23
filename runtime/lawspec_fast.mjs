/**
 * Typed values for generated checked definitions and stateful spec handlers.
 *
 * A definition whose types all have a typed form runs over these instead of
 * the dynamic values: Bool and Text are JavaScript's own, Bytes a Uint8Array
 * no one changes, and Unit null. An integer of at most 32 bits is a number;
 * Int64, UInt64 and Integer are a number while they are safe integers and a
 * BigInt beyond, so arithmetic stays exact and usually costs what a number's
 * does. Maybe is null or a Present, Either a Side, a List null or a Cons cell
 * that shares its tail, KeyVal and Set persistent AVL trees in the portable
 * order whose updates copy only the path to a key, and data the generated
 * classes (a rank alone for a type whose constructors have no fields). A
 * handler's state is therefore shared, never copied, from one operation to
 * the next. The generated lawspec_typed module converts each typed value to
 * and from the dynamic values where typed and dynamic code meet.
 * ref:DEC-typed-native-definitions
 */
import * as ls from "./lawspec_runtime.mjs";

export class Cons {
  h;
  t;
  n;
  constructor(h, t) {
    this.h = h;
    this.t = t;
    this.n = t === null ? 1 : t.n + 1;
  }
}

export class Present {
  v;
  constructor(v) {
    this.v = v;
  }
}

export class Side {
  r;
  v;
  constructor(r, v) {
    this.r = r;
    this.v = v;
  }
}

export class Node {
  k;
  v;
  l;
  r;
  h;
  constructor(k, v, l, r, h) {
    this.k = k;
    this.v = v;
    this.l = l;
    this.r = r;
    this.h = h;
  }
}

export function cons(h, t) {
  return new Cons(h, t);
}

export function present(v) {
  return new Present(v);
}

export function left(v) {
  return new Side(false, v);
}

export function right(v) {
  return new Side(true, v);
}

// Arrow functions, so TypeScript knows they never return.
export const unreachable = () => {
  throw new Error("unreachable branch reached");
};

export const outside = (t) => {
  throw new RangeError(`integer outside ${t} range`);
};

// Integers: a number while safe, a BigInt beyond.

const MAX = BigInt(Number.MAX_SAFE_INTEGER);
const MIN = -MAX;

export function norm(x) {
  return x >= MIN && x <= MAX ? Number(x) : x;
}

export function big(x) {
  return typeof x === "bigint" ? x : BigInt(x);
}

export function add(a, b) {
  if (typeof a === "number" && typeof b === "number") {
    const r = a + b;
    if (Number.isSafeInteger(r)) return r;
  }
  return norm(big(a) + big(b));
}

export function sub(a, b) {
  if (typeof a === "number" && typeof b === "number") {
    const r = a - b;
    if (Number.isSafeInteger(r)) return r;
  }
  return norm(big(a) - big(b));
}

export function mul(a, b) {
  if (typeof a === "number" && typeof b === "number") {
    const r = a * b;
    if (Number.isSafeInteger(r)) return r + 0;
  }
  return norm(big(a) * big(b));
}

export function neg(a) {
  return typeof a === "number" ? 0 - a : norm(-a);
}

// quot truncates; rem takes the dividend's sign.
export function quot(a, b) {
  if (b === 0 || b === 0n) throw new RangeError("exact division by zero");
  if (typeof a === "number" && typeof b === "number")
    return (a - (a % b)) / b + 0;
  return norm(big(a) / big(b));
}

export function rem(a, b) {
  if (b === 0 || b === 0n) throw new RangeError("exact division by zero");
  if (typeof a === "number" && typeof b === "number") return (a % b) + 0;
  return norm(big(a) % big(b));
}

export function power(a, b) {
  if (b < 0) throw new RangeError("negative exponent");
  if (b > 2147483648) throw new RangeError("exponent too large");
  return norm(big(a) ** big(b));
}

export function narrow(v, lo, hi, t) {
  if (v < lo || v > hi) outside(t);
  return v;
}

export function cmpNumber(a, b) {
  return a < b ? -1 : a > b ? 1 : 0;
}

export function cmpBool(a, b) {
  return a === b ? 0 : a ? 1 : -1;
}

export function cmpUnit() {
  return 0;
}

export function eqUnit() {
  return true;
}

export function eqPlain(a, b) {
  return a === b;
}

// Text is ordered by code point, as UTF-16 code units are but for
// surrogates, which come after U+E000 to U+FFFF.
export function cmpText(a, b) {
  if (a === b) return 0;
  const n = a.length < b.length ? a.length : b.length;
  for (let i = 0; i < n; i++) {
    let x = a.charCodeAt(i);
    let y = b.charCodeAt(i);
    if (x !== y) {
      if (x >= 0xd800 && y >= 0xd800) {
        x = x >= 0xe000 ? x - 0x800 : x + 0x2000;
        y = y >= 0xe000 ? y - 0x800 : y + 0x2000;
      }
      return x < y ? -1 : 1;
    }
  }
  return a.length < b.length ? -1 : a.length > b.length ? 1 : 0;
}

function plain(s) {
  for (let i = 0; i < s.length; i++) {
    const c = s.charCodeAt(i);
    if (c >= 0xd800 && c <= 0xdfff) return false;
  }
  return true;
}

export function textLength(s) {
  if (plain(s)) return s.length;
  let n = 0;
  for (const _ of s) n++;
  return n;
}

export function eqBytes(a, b) {
  if (a === b) return true;
  if (a.length !== b.length) return false;
  for (let i = 0; i < a.length; i++) if (a[i] !== b[i]) return false;
  return true;
}

export function cmpBytes(a, b) {
  const n = a.length < b.length ? a.length : b.length;
  for (let i = 0; i < n; i++) if (a[i] !== b[i]) return a[i] < b[i] ? -1 : 1;
  return a.length < b.length ? -1 : a.length > b.length ? 1 : 0;
}

export function appendBytes(a, b) {
  const out = new Uint8Array(a.length + b.length);
  out.set(a, 0);
  out.set(b, a.length);
  return out;
}

// Lists.

export function length(xs) {
  return xs === null ? 0 : xs.n;
}

export function listOf(values) {
  let out = null;
  for (let i = values.length - 1; i >= 0; i--) out = new Cons(values[i], out);
  return out;
}

export function items(xs) {
  const out = [];
  for (let c = xs; c !== null; c = c.t) out.push(c.h);
  return out;
}

export function eqList(a, b, eq) {
  for (;;) {
    if (a === b) return true;
    if (a === null || b === null || a.n !== b.n || !eq(a.h, b.h)) return false;
    a = a.t;
    b = b.t;
  }
}

export function cmpList(a, b, cmp) {
  for (;;) {
    if (a === b) return 0;
    if (a === null) return -1;
    if (b === null) return 1;
    const c = cmp(a.h, b.h);
    if (c !== 0) return c;
    a = a.t;
    b = b.t;
  }
}

export function append(a, b) {
  const xs = items(a);
  let out = b;
  for (let i = xs.length - 1; i >= 0; i--) out = new Cons(xs[i], out);
  return out;
}

function clamp(i, count) {
  return i < 0 ? 0 : i > count ? count : Number(i);
}

export function sliceList(xs, from, to) {
  const count = length(xs);
  const i = clamp(from, count);
  let j = clamp(to, count);
  if (j < i) j = i;
  let rest = xs;
  for (let k = 0; k < i; k++) rest = rest.t;
  if (j === count) return rest;
  const taken = [];
  for (let c = rest; taken.length < j - i; c = c.t) taken.push(c.h);
  return listOf(taken);
}

export function sliceText(s, from, to) {
  if (plain(s)) {
    const i = clamp(from, s.length);
    let j = clamp(to, s.length);
    if (j < i) j = i;
    return s.slice(i, j);
  }
  const points = [...s];
  const i = clamp(from, points.length);
  let j = clamp(to, points.length);
  if (j < i) j = i;
  return points.slice(i, j).join("");
}

export function sliceBytes(s, from, to) {
  const i = clamp(from, s.length);
  let j = clamp(to, s.length);
  if (j < i) j = i;
  return s.slice(i, j);
}

export function atList(xs, i) {
  if (i < 0 || i >= length(xs)) return null;
  let c = xs;
  for (let k = 0; k < i; k++) c = c.t;
  return new Present(c.h);
}

export function atBytes(s, i) {
  if (i < 0 || i >= s.length) return null;
  return new Present(s[Number(i)]);
}

export function range(lo, hi) {
  let out = null;
  if (typeof lo === "number" && typeof hi === "number") {
    for (let k = hi - 1; k >= lo; k--) out = new Cons(k, out);
    return out;
  }
  for (let k = big(hi) - 1n; k >= big(lo); k--) out = new Cons(norm(k), out);
  return out;
}

export function octets(b) {
  return listOf(Array.from(b));
}

export function bytesOf(xs) {
  return Uint8Array.from(items(xs));
}

const encoder = new TextEncoder();
export function utf8(t) {
  return encoder.encode(t);
}

export function join(separator, parts) {
  return items(parts).join(separator);
}

export function regexMatches(pattern, text) {
  return ls.regexMatches(pattern, text);
}

// Persistent maps: null is empty. Every function takes the keys' order,
// cmp(a, b) -> -1, 0 or 1.

function height(m) {
  return m === null ? 0 : m.h;
}

function node(k, v, l, r) {
  const hl = height(l);
  const hr = height(r);
  return new Node(k, v, l, r, (hl > hr ? hl : hr) + 1);
}

function balance(k, v, l, r) {
  const hl = height(l);
  const hr = height(r);
  if (hl > hr + 1) {
    if (height(l.l) >= height(l.r))
      return node(l.k, l.v, l.l, node(k, v, l.r, r));
    return node(l.r.k, l.r.v, node(l.k, l.v, l.l, l.r.l), node(k, v, l.r.r, r));
  }
  if (hr > hl + 1) {
    if (height(r.r) >= height(r.l))
      return node(r.k, r.v, node(k, v, l, r.l), r.r);
    return node(r.l.k, r.l.v, node(k, v, l, r.l.l), node(r.k, r.v, r.l.r, r.r));
  }
  return new Node(k, v, l, r, (hl > hr ? hl : hr) + 1);
}

export function lookup(m, k, cmp) {
  while (m !== null) {
    const c = cmp(k, m.k);
    if (c === 0) return new Present(m.v);
    m = c < 0 ? m.l : m.r;
  }
  return null;
}

export function member(m, k, cmp) {
  while (m !== null) {
    const c = cmp(k, m.k);
    if (c === 0) return true;
    m = c < 0 ? m.l : m.r;
  }
  return false;
}

export function put(m, k, v, cmp) {
  if (m === null) return new Node(k, v, null, null, 1);
  const c = cmp(k, m.k);
  if (c === 0) return new Node(k, v, m.l, m.r, m.h);
  if (c < 0) return balance(m.k, m.v, put(m.l, k, v, cmp), m.r);
  return balance(m.k, m.v, m.l, put(m.r, k, v, cmp));
}

function withoutMin(m) {
  if (m.l === null) return [m.k, m.v, m.r];
  const [k, v, rest] = withoutMin(m.l);
  return [k, v, balance(m.k, m.v, rest, m.r)];
}

function joinTrees(l, r) {
  if (l === null) return r;
  if (r === null) return l;
  const [k, v, rest] = withoutMin(r);
  return balance(k, v, l, rest);
}

export function remove(m, k, cmp) {
  if (m === null) return null;
  const c = cmp(k, m.k);
  if (c === 0) return joinTrees(m.l, m.r);
  if (c < 0) {
    const l = remove(m.l, k, cmp);
    return l === m.l ? m : balance(m.k, m.v, l, m.r);
  }
  const r = remove(m.r, k, cmp);
  return r === m.r ? m : balance(m.k, m.v, m.l, r);
}

export function each(m, f) {
  const stack = [];
  while (stack.length > 0 || m !== null) {
    while (m !== null) {
      stack.push(m);
      m = m.l;
    }
    m = stack.pop();
    f(m.k, m.v);
    m = m.r;
  }
}

export function entries(m) {
  const out = [];
  each(m, (k, v) => out.push([k, v]));
  return out;
}

export function size(m) {
  let n = 0;
  each(m, () => n++);
  return n;
}

export function keysList(m) {
  const out = [];
  each(m, (k) => out.push(k));
  return listOf(out);
}

export function valuesList(m) {
  const out = [];
  each(m, (_, v) => out.push(v));
  return listOf(out);
}

export function entriesList(m, entry) {
  const out = [];
  each(m, (k, v) => out.push(entry(k, v)));
  return listOf(out);
}

export function keyValOf(es, key, value, cmp) {
  let m = null;
  for (let c = es; c !== null; c = c.t) m = put(m, key(c.h), value(c.h), cmp);
  return m;
}

export function setOf(xs, cmp) {
  let s = null;
  for (let c = xs; c !== null; c = c.t)
    if (!member(s, c.h, cmp)) s = put(s, c.h, null, cmp);
  return s;
}

export function setInsert(s, x, cmp) {
  return member(s, x, cmp) ? s : put(s, x, null, cmp);
}

export function setUnion(a, b, cmp) {
  let small = a;
  let large = b;
  if (size(a) > size(b)) {
    small = b;
    large = a;
  }
  each(small, (k) => {
    large = setInsert(large, k, cmp);
  });
  return large;
}

export function setIntersection(a, b, cmp) {
  let out = null;
  each(a, (k) => {
    if (member(b, k, cmp)) out = put(out, k, null, cmp);
  });
  return out;
}

export function setDifference(a, b, cmp) {
  let out = null;
  each(a, (k) => {
    if (!member(b, k, cmp)) out = put(out, k, null, cmp);
  });
  return out;
}

export function eqMap(a, b, ek, ev) {
  if (a === b) return true;
  const x = entries(a);
  const y = entries(b);
  if (x.length !== y.length) return false;
  for (let i = 0; i < x.length; i++)
    if (!ek(x[i][0], y[i][0]) || !ev(x[i][1], y[i][1])) return false;
  return true;
}

export function cmpMap(a, b, ck, cv) {
  const x = entries(a);
  const y = entries(b);
  for (let i = 0; i < x.length && i < y.length; i++) {
    const c = ck(x[i][0], y[i][0]);
    if (c !== 0) return c;
    const d = cv(x[i][1], y[i][1]);
    if (d !== 0) return d;
  }
  return x.length < y.length ? -1 : x.length > y.length ? 1 : 0;
}

export function eqMaybe(a, b, eq) {
  return a === null || b === null ? a === b : eq(a.v, b.v);
}

export function cmpMaybe(a, b, cmp) {
  if (a === null || b === null) return a === b ? 0 : a === null ? -1 : 1;
  return cmp(a.v, b.v);
}

export function eqEither(a, b, el, er) {
  return a.r === b.r && (a.r ? er(a.v, b.v) : el(a.v, b.v));
}

export function cmpEither(a, b, cl, cr) {
  if (a.r !== b.r) return a.r ? 1 : -1;
  return a.r ? cr(a.v, b.v) : cl(a.v, b.v);
}

// Failures, as the dynamic code raises and catches them.

export function fail(ability, value) {
  throw new ls.Failure(ability, value);
}

// The dynamic values: integers are BigInts there.

export function toListValue(xs, f) {
  const out = [];
  for (let c = xs; c !== null; c = c.t) out.push(f(c.h));
  return out;
}

export function fromListValue(v, f) {
  let out = null;
  for (let i = v.length - 1; i >= 0; i--) out = new Cons(f(v[i]), out);
  return out;
}

export function data(tag, fields) {
  return new ls.DataValue(tag, fields);
}

// Whether lawspec.json bound the native types a handler's values cross
// with: then they cross through the handler schema, not directly.
export function bound() {
  return ls.handlerSchemaBound();
}
