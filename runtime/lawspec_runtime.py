"""LawSpec scalar runtime, independent of test frameworks."""
from collections import deque  # noqa: F401  (native Queue, Stack, Deque)
from datetime import timedelta  # noqa: F401  (native Duration)
from dataclasses import dataclass
from fractions import Fraction
from decimal import Decimal
import math
import struct


@dataclass(frozen=True)
class Presence:
    kind: str
    present: bool
    value: object = None


@dataclass(eq=False, frozen=True)
class DataValue:
    tag: str
    fields: tuple

    def __post_init__(self):
        object.__setattr__(self, 'fields', tuple(self.fields))


@dataclass(frozen=True)
class Raw:
    kind: str
    units: tuple

    def __post_init__(self):
        object.__setattr__(self, 'units', tuple(self.units))


@dataclass(eq=False, frozen=True)
class Symbol:
    description: str


@dataclass(frozen=True)
class Absence:
    kind: str


(UNIT, NULL, UNDEFINED) = (Absence(t) for t in ('Unit', 'Null', 'Undefined'))


def integer_type(t):
    return t.startswith(('Int', 'UInt')) or t in ('BigInt', 'BigUInt')


def exact_type(t):
    return integer_type(t) or t in ('Decimal', 'Rational')


def bounds(t, bits=64):
    if t in ('Integer', 'BigInt', 'BigUInt'):
        return (0 if t == 'BigUInt' else None, None)
    width = (bits if t in ('IntSize', 'UIntSize', 'UIntPtr') else
             int(t[4:] if t.startswith('UInt') else t[3:]))
    return ((0, 2 ** width - 1) if t.startswith('U') else
            (-2 ** (width - 1), 2 ** (width - 1) - 1))


def f32(x):
    try:
        return struct.unpack('>f', struct.pack('>f', x))[0]
    except OverflowError:
        return math.copysign(math.inf, x)


def ratio(x):
    if isinstance(x, bool):
        raise ValueError('Bool is not an integer')
    return Fraction(x)


def finite_decimal(r):
    r = ratio(r)
    (d, a, b) = (r.denominator, 0, 0)
    while d % 2 == 0:
        d //= 2
        a += 1
    while d % 5 == 0:
        d //= 5
        b += 1
    if d != 1:
        raise ValueError('Decimal conversion is not finite; use round')
    scale = max(a, b)
    c = r.numerator * 2 ** (scale - a) * 5 ** (scale - b)
    return Decimal((int(c < 0), tuple(map(int, integer_text(abs(c)))), -scale))


def convert(x, t, bits=64):
    if integer_type(t):
        r = ratio(x)
        if r.denominator != 1:
            raise ValueError('fractional conversion to ' + t)
        x = r.numerator
        (lo, hi) = bounds(t, bits)
        if lo is not None and x < lo or (hi is not None and x > hi):
            raise ValueError('integer outside ' + t + ' range')
        return x
    if t == 'Rational':
        return ratio(x)
    if t == 'Decimal':
        return finite_decimal(x)
    if t in ('Float32', 'Float64'):
        if not isinstance(x, float):
            return exact_float(ratio(x), t)
        try:
            v = float(x)
        except OverflowError:
            v = math.copysign(math.inf, -1 if x < 0 else 1)
        return f32(v) if t == 'Float32' else v
    if t in ('Complex64', 'Complex128'):
        z = (x if isinstance(x, complex) else
             complex(
                 convert(x, 'Float32' if t == 'Complex64' else 'Float64'), 0))
        return complex(f32(z.real), f32(z.imag)) if t == 'Complex64' else z
    return validate(x, t, bits)


def valid_unit(t, c):
    maximum = (255 if t == 'Bytes' else
               65535 if t in ('Utf16Text', 'CodeUnit16') else 1114111)
    return (type(c) is int and 0 <= c <= maximum and
            (t not in ('Text', 'Char') or not 55296 <= c <= 57343))


def validate(x, t, bits=64):
    if t.startswith('Either '):
        types = either_arguments(t)
        if (not isinstance(x, DataValue) or len(x.fields) != 1 or
                x.tag not in ('Either::Left', 'Either::Right')):
            raise ValueError('invalid Either constructor or arity')
        inner = types[0 if x.tag == 'Either::Left' else 1]
        return DataValue(x.tag, (validate(x.fields[0], inner, bits),))
    if t.startswith('Maybe '):
        if not isinstance(x, DataValue):
            raise TypeError('expected Maybe')
        if x.tag == 'Maybe::Nothing' and (not x.fields):
            return x
        if x.tag == 'Maybe::Just' and len(x.fields) == 1:
            return DataValue(x.tag, (validate(x.fields[0], t[6:], bits),))
        raise ValueError('invalid Maybe constructor or arity')
    if t.startswith('List '):
        if not isinstance(x, list):
            raise TypeError('expected List')
        return [validate(value, t[5:], bits) for value in x]
    if t.startswith(('Nullable ', 'Optional ')):
        (k, inner) = t.split(' ', 1)
        if (not isinstance(x, Presence) or x.kind != k or
                type(x.present) is not bool):
            raise ValueError('tagged presence required for ' + t)
        if x.present:
            return Presence(k, True, validate(x.value, inner, bits))
    elif integer_type(t):
        if type(x) is not int:
            raise ValueError('integer required for ' + t)
        convert(x, t, bits)
    elif t == 'Bool':
        if type(x) is not bool:
            raise ValueError('Bool required')
    elif t in ('Text', 'Char'):
        if (not isinstance(x, str) or (t == 'Char' and len(x) != 1) or
                not all(valid_unit(t, ord(c)) for c in x)):
            raise ValueError('invalid ' + t)
    elif t in ('CodePoint', 'CodeUnit16'):
        if not valid_unit(t, x):
            raise ValueError('invalid ' + t)
    elif t == 'Bytes':
        if type(x) is not bytes:
            raise ValueError('Bytes required')
    elif t in ('CodePointText', 'Utf16Text'):
        if (not isinstance(x, Raw) or x.kind != t or
                not all(valid_unit(t, c) for c in x.units)):
            raise ValueError('invalid ' + t)
    elif t in ('Unit', 'Null', 'Undefined'):
        if x != Absence(t):
            raise ValueError('invalid ' + t)
    elif t == 'Symbol':
        if not isinstance(x, Symbol):
            raise ValueError('Symbol required')
    elif t == 'Decimal':
        if not isinstance(x, Decimal) or not x.is_finite():
            raise ValueError('finite Decimal required')
    elif t == 'Rational':
        if not isinstance(x, Fraction):
            raise ValueError('Rational required')
    elif t in ('Float32', 'Float64'):
        if (type(x) is not float or
                (t == 'Float32' and not math.isnan(x) and f32(x) != x)):
            raise ValueError('invalid ' + t)
    elif t in ('Complex64', 'Complex128'):
        if type(x) is not complex:
            raise ValueError('complex required')
        if t == 'Complex64':
            validate(x.real, 'Float32')
            validate(x.imag, 'Float32')
    else:
        raise ValueError('unknown scalar type ' + t)
    return x


def literal(v, symbols=None):
    t = v['type']
    if integer_type(t):
        return parse_integer(v['value'])
    if t == 'Bool':
        return v['value']
    if t == 'Decimal':
        c = parse_integer(v['coefficient'])
        return Decimal((int(c < 0), tuple(map(int, integer_text(abs(c)))),
                        int(v['exponent'])))
    if t == 'Rational':
        return Fraction(parse_integer(v['numerator']),
                        parse_integer(v['denominator']))
    if t.startswith('Float'):
        return struct.unpack('>f' if t == 'Float32' else '>d',
                             bytes.fromhex(v['bits']))[0]
    if t.startswith('Complex'):
        return complex(literal(v['real']), literal(v['imaginary']))
    if t == 'Text':
        return ''.join(map(chr, v['units']))
    if t == 'Char':
        return chr(v['value'])
    if t in ('CodePoint', 'CodeUnit16'):
        return v['value']
    if t == 'Bytes':
        return bytes(v['units'])
    if t in ('CodePointText', 'Utf16Text'):
        return Raw(t, tuple(v['units']))
    if t == 'Symbol':
        if symbols is None:
            symbols = {}
        return symbols.setdefault(v['id'], Symbol(v['description']))
    if t in ('Nullable', 'Optional'):
        return Presence(
            t, v['value'] is not None,
            literal(v['value'], symbols) if v['value'] is not None else None)
    return Absence(t)


def promote(a, b, op):
    if exact_type(a) != exact_type(b):
        raise ValueError('exact/inexact mixing requires explicit conversion')
    if exact_type(a):
        return ('Rational' if op == '/' or 'Rational' in (a, b) else
                'Decimal' if 'Decimal' in (a, b) else 'Integer')
    if a.startswith('Complex') or b.startswith('Complex'):
        return ('Complex128' if a in ('Float64', 'Complex128') or
                b in ('Float64', 'Complex128') else 'Complex64')
    return 'Float64' if 'Float64' in (a, b) else 'Float32'


def ieee_div(a, b):
    if b != 0:
        return a / b
    if a == 0 or math.isnan(a):
        return math.nan
    return math.copysign(math.inf, math.copysign(1, a) * math.copysign(1, b))


def binary(op, a, b, ta, tb):
    if (op in ('==', '!=') and not exact_type(ta) and
            ta not in ('Float32', 'Float64', 'Complex64', 'Complex128')):
        result = equal(a, b, ta, tb)
        return result if op == '==' else not result
    t = promote(ta, tb, op)
    if exact_type(ta):
        (a, b) = (ratio(a), ratio(b))
    elif t.startswith('Complex'):
        (a, b) = (complex(a), complex(b))
        rnd = f32 if t == 'Complex64' else float
        if op == '+':
            return complex(rnd(a.real + b.real), rnd(a.imag + b.imag))
        if op == '-':
            return complex(rnd(a.real - b.real), rnd(a.imag - b.imag))
        if op == '*':
            return complex(
                rnd(rnd(a.real * b.real) - rnd(a.imag * b.imag)),
                rnd(rnd(a.real * b.imag) + rnd(a.imag * b.real)))
        if op == '/':
            d = rnd(rnd(b.real * b.real) + rnd(b.imag * b.imag))
            return complex(
                rnd(ieee_div(
                    rnd(rnd(a.real * b.real) + rnd(a.imag * b.imag)), d)),
                rnd(ieee_div(
                    rnd(rnd(a.imag * b.real) - rnd(a.real * b.imag)), d)))
    if op == 'pow':
        if a.denominator != 1 or b.denominator != 1:
            raise TypeError('pow requires integer operands')
        if b < 0:
            raise ValueError('negative exponent')
        return a.numerator ** b.numerator
    if op in ('quot', 'rem'):
        q = abs(a.numerator) // abs(b.numerator)
        if (a < 0) != (b < 0):
            q = -q
        return q if op == 'quot' else a.numerator - q * b.numerator
    if op in ('<', '<=', '>', '>=', '==', '!='):
        return {
            '<': lambda: a < b,
            '<=': lambda: a <= b,
            '>': lambda: a > b,
            '>=': lambda: a >= b,
            '==': lambda: a == b,
            '!=': lambda: a != b,
        }[op]()
    if op == '+':
        v = a + b
    elif op == '-':
        v = a - b
    elif op == '*':
        v = a * b
    elif op == '/':
        v = a / b if exact_type(ta) else ieee_div(a, b)
    else:
        raise ValueError('unknown operation ' + op)
    return convert(v, t)


def equal(a, b, ta, tb):
    if ta.startswith('Either ') and tb.startswith('Either '):
        if a.tag != b.tag:
            return False
        index = 0 if a.tag == 'Either::Left' else 1
        return equal(a.fields[0], b.fields[0],
                     either_arguments(ta)[index], either_arguments(tb)[index])
    if ta.startswith('Maybe ') and tb.startswith('Maybe '):
        return (a.tag == b.tag and
                (a.tag == 'Maybe::Nothing' or
                 equal(a.fields[0], b.fields[0], ta[6:], tb[6:])))
    if ta.startswith('List ') and tb.startswith('List '):
        return (len(a) == len(b) and
                all(equal(x, y, ta[5:], tb[5:]) for x, y in zip(a, b)))
    if exact_type(ta) and exact_type(tb):
        return ratio(a) == ratio(b)
    if isinstance(a, Presence) and isinstance(b, Presence):
        return (a.kind == b.kind and a.present == b.present and
                (not a.present or
                 equal(a.value, b.value,
                       ta.split(' ', 1)[1], tb.split(' ', 1)[1])))
    if isinstance(a, complex) and isinstance(b, complex):
        return a.real == b.real and a.imag == b.imag
    return a == b


def _run_blocking(main):
    """Runs a coroutine to completion and returns its result. Called where an
    event loop is already running (a synchronous definition called from an
    asynchronous adapter), it runs on a thread of its own."""
    import asyncio
    try:
        asyncio.get_running_loop()
    except RuntimeError:
        return asyncio.run(main)
    import concurrent.futures
    with concurrent.futures.ThreadPoolExecutor(max_workers=1) as pool:
        return pool.submit(asyncio.run, main).result()


def await_task(task):
    """An async adapter's result: run its coroutine (or awaitable) to completion."""
    async def result():
        return await task
    return _run_blocking(result())


ORDERING = 'lawspec.collections::type::Ordering::'


def compare_values(a, b):
    """The portable total order: -1, 0 or 1.

    Exact numbers by value, text and raw sequences by unit, False before True,
    absence before presence, lists element by element, Nothing before Just,
    and other data by constructor identity, then fields left to right.
    """
    if isinstance(a, bool) and isinstance(b, bool):
        return (a > b) - (a < b)
    if isinstance(a, (int, Fraction, Decimal)) and not isinstance(a, bool):
        x, y = ratio(a), ratio(b)
        return (x > y) - (x < y)
    if isinstance(a, str) and isinstance(b, str):
        return (a > b) - (a < b)
    if isinstance(a, Raw) and isinstance(b, Raw):
        return (a.units > b.units) - (a.units < b.units)
    if isinstance(a, Absence) and isinstance(b, Absence):
        return 0
    if isinstance(a, Presence) and isinstance(b, Presence):
        if a.present != b.present:
            return 1 if a.present else -1
        return compare_values(a.value, b.value) if a.present else 0
    if isinstance(a, (list, tuple)) and isinstance(b, (list, tuple)):
        for x, y in zip(a, b):
            order = compare_values(x, y)
            if order:
                return order
        return (len(a) > len(b)) - (len(a) < len(b))
    if isinstance(a, DataValue) and isinstance(b, DataValue):
        if a.tag != b.tag:
            if {a.tag, b.tag} == {'Maybe::Nothing', 'Maybe::Just'}:
                return -1 if a.tag == 'Maybe::Nothing' else 1
            return (a.tag > b.tag) - (a.tag < b.tag)
        return compare_values(list(a.fields), list(b.fields))
    raise TypeError('values have no portable order')


def helper(n, args, types, bits=64):
    x = args[0]
    if n == 'checked':
        return True
    if n == 'select':
        return args[1] if args[0] else args[2]
    if n == 'compare':
        order = compare_values(args[0], args[1])
        return DataValue(ORDERING + ('Less', 'Equal', 'Greater')[order + 1], ())
    if n == 'length':
        return len(x.units) if isinstance(x, Raw) else len(x)
    if n == 'isPresent':
        return x.present
    if n == 'presentValue':
        if not x.present:
            raise ValueError('absent presence value')
        return x.value
    if n == 'real':
        return x.real
    if n == 'imag':
        return x.imag
    if n == 'negate':
        if exact_type(types[0]):
            return binary('-', 0, x, 'BigInt', types[0])
        return convert(-x, types[0])
    if n in ('quot', 'rem', 'pow'):
        return binary(n, *args, *types)
    if n == 'isNaN':
        return math.isnan(x)
    if n == 'isInfinite':
        return math.isinf(x)
    if n == 'isFinite':
        return math.isfinite(x)
    if n == 'isNegativeZero':
        return x == 0 and math.copysign(1, x) < 0
    if n == 'round':
        scale = convert(args[1], 'Int32', bits)
        factor = (Fraction(10 ** scale) if scale >= 0 else
                  Fraction(1, 10 ** (-scale)))
        return finite_decimal(Fraction(round(ratio(x) * factor), 1) / factor)
    return convert(x, n, bits)


def make_decimal(c, e):
    return Decimal((int(c < 0), tuple(map(int, integer_text(abs(c)))), e))


def exact_float(r, t):
    if not r:
        return 0.0
    negative = r < 0
    (n, d) = (abs(r.numerator), r.denominator)
    single = t == 'Float32'
    (p, bias) = (24, 127) if single else (53, 1023)
    (emin, emax) = (1 - bias, bias)
    e = n.bit_length() - d.bit_length()
    if n < d << e if e >= 0 else n << -e < d:
        e -= 1
    if e > emax:
        return -math.inf if negative else math.inf
    scale = max(e, emin) - (p - 1)
    (num, den) = (n << -scale if scale < 0 else n,
                  d << scale if scale > 0 else d)
    (q, rem) = divmod(num, den)
    if 2 * rem > den or (2 * rem == den and q % 2):
        q += 1
    e = max(e, emin)
    if q == 1 << p:
        q >>= 1
        e += 1
    if e > emax:
        return -math.inf if negative else math.inf
    hidden = 1 << p - 1
    exponent = 0 if q < hidden else e + bias
    mantissa = q if q < hidden else q - hidden
    bits = (int(negative) << (31 if single else 63) |
            exponent << p - 1 | mantissa)
    return struct.unpack('>f' if single else '>d',
                         bits.to_bytes(4 if single else 8, 'big'))[0]


def parse_integer(text):
    negative = text.startswith('-')
    text = text.lstrip('+-')
    if not text or not text.isascii() or (not text.isdigit()):
        raise ValueError('invalid integer representation')
    result = 0
    for start in range(0, len(text), 9):
        chunk = text[start:start + 9]
        result = result * 10 ** len(chunk) + int(chunk)
    return -result if negative else result


def integer_text(value):
    if value == 0:
        return '0'
    (negative, value) = (value < 0, abs(value))
    chunks = []
    while value:
        (value, rest) = divmod(value, 1000000000)
        chunks.append(rest)
    return (('-' if negative else '') + str(chunks[-1]) +
            ''.join(f'{n:09d}' for n in reversed(chunks[:-1])))


def unit_result(value):
    return UNIT if value is None else validate(value, 'Unit')


# Dependent-domain operations are independent of test frameworks.
def sample(t, seed, bits=64):
    import random
    r = random.Random(seed)
    if t.startswith(('Nullable ', 'Optional ')):
        (kind, inner) = t.split(' ', 1)
        return Presence(kind, bool(seed % 2),
                        sample(inner, seed // 2, bits) if seed % 2 else None)
    if integer_type(t):
        (lo, hi) = bounds(t, bits)
        return r.randint(lo if lo is not None else -2 ** 256,
                         hi if hi is not None else 2 ** 256)
    if t == 'Bool':
        return bool(seed % 2)
    if t == 'Decimal':
        return make_decimal(r.randint(-2 ** 128, 2 ** 128), r.randint(-20, 20))
    if t == 'Rational':
        return Fraction(r.randint(-2 ** 128, 2 ** 128), r.randint(1, 2 ** 128))
    if t.startswith('Float'):
        return literal({
            'type': t,
            'bits': format(r.getrandbits(32 if t == 'Float32' else 64),
                           '08x' if t == 'Float32' else '016x'),
        })
    if t.startswith('Complex'):
        c = 'Float32' if t == 'Complex64' else 'Float64'
        return complex(sample(c, seed, bits), sample(c, seed + 1, bits))
    if t in ('Unit', 'Null', 'Undefined'):
        return {'Unit': UNIT, 'Null': NULL, 'Undefined': UNDEFINED}[t]
    if t == 'Symbol':
        return Symbol('same')
    maximum = (255 if t == 'Bytes' else
               65535 if t in ('Utf16Text', 'CodeUnit16') else 1114111)

    def unit():
        while True:
            c = r.randint(0, maximum)
            if t not in ('Text', 'Char') or not 55296 <= c <= 57343:
                return c
    if t == 'Char':
        return chr(unit())
    if t in ('CodePoint', 'CodeUnit16'):
        return unit()
    units = tuple((unit() for _ in range(r.randint(0, 39))))
    if t == 'Text':
        return ''.join(map(chr, units))
    if t == 'Bytes':
        return bytes(units)
    return Raw(t, units)


def domain_candidates(t, seed, bits, restrictions, hints):
    candidates = []
    for hint in hints:
        try:
            candidates.append(convert(hint, t, bits))
        except (ValueError, TypeError, OverflowError):
            pass
    if integer_type(t):
        (lo, hi) = bounds(t, bits)
        for (op, value) in restrictions:
            r = ratio(value)
            if op in ('>', '>=', '=='):
                bound = math.floor(r) + 1 if op == '>' else math.ceil(r)
                lo = bound if lo is None else max(lo, bound)
            if op in ('<', '<=', '=='):
                bound = math.ceil(r) - 1 if op == '<' else math.floor(r)
                hi = bound if hi is None else min(hi, bound)
        if lo is not None and hi is not None and (lo > hi):
            return []
        lower = lo if lo is not None else min(-2 ** 256, (hi or 0) - 2 ** 256)
        upper = hi if hi is not None else max(2 ** 256, (lo or 0) + 2 ** 256)
        candidates += [lower, upper, 0, 1, -1, lower + 1, upper - 1]
        import random
        r = random.Random(seed)
        candidates += [r.randint(lower, upper) for _ in range(8)]
        candidates = [
            v for v in candidates
            if isinstance(v, int) and not isinstance(v, bool)
            and lower <= v <= upper
        ]
    else:
        candidates += [sample(t, seed + j * 7919, bits) for j in range(8)]
    if candidates:
        offset = seed % len(candidates)
        candidates = candidates[offset:] + candidates[:offset]
    return candidates


def generate_tuple(domains, seed, attempts, prefix=()):
    used = 0
    last_prefix = list(prefix)

    def search(values):
        nonlocal used, last_prefix
        last_prefix = values
        if len(values) == len(domains):
            return values
        if used >= attempts:
            return None
        used += 1
        (candidates, accept) = domains[len(values)]
        for value in candidates(values, seed + used * 7919):
            if used >= attempts:
                break
            used += 1
            next_values = values + [value]
            if accept(next_values):
                result = search(next_values)
                if result is not None:
                    return result
        return None
    while used < attempts:
        result = search(list(prefix))
        if result is not None:
            return result
    raise ValueError(
        f'refinement-generation-exhausted after {used} attempts; '
        f'prefix={last_prefix!r}; seed={seed}')


def require_contract(condition, context):
    if condition is not True:
        raise ValueError(context)


def refined_case(
        domains, seed, attempts, shrinks, check, context='refinement'):
    try:
        values = generate_tuple(domains, seed, attempts)
    except Exception as error:
        raise ValueError(f'{context}: {error}') from error
    try:
        check(values)
    except Exception as original:
        best = values
        budget = shrinks
        for index in range(len(best)):
            value = best[index]
            candidates = domains[index][0](best[:index], 0)
            if isinstance(value, int) and (not isinstance(value, bool)):
                candidates = [0, 1 if value > 0 else -1] + candidates
                reduced = value
                while abs(reduced) > 1:
                    reduced = abs(reduced) // 2 * (1 if reduced > 0 else -1)
                    candidates.insert(2, reduced)
            for candidate in candidates:
                if budget <= 0:
                    break
                budget -= 1
                if complexity(candidate) >= complexity(best[index]):
                    continue
                prefix = best[:index] + [candidate]
                if not domains[index][1](prefix):
                    continue
                try:
                    trial = generate_tuple(domains, seed,
                                           min(attempts, 100), prefix)
                except ValueError as error:
                    if str(error).startswith(
                            'refinement-generation-exhausted'):
                        continue
                    raise
                try:
                    check(trial)
                except Exception:
                    best = trial
        raise AssertionError(
            f'{context}: {original}; refined counterexample={best!r}; '
            f'seed={seed}') from original


def complexity(value):
    if isinstance(value, Presence):
        return 1 + complexity(value.value) if value.present else 0
    if isinstance(value, Raw):
        return len(value.units)
    if isinstance(value, (str, bytes)):
        return len(value)
    if isinstance(value, Absence):
        return 0
    if isinstance(value, Symbol):
        return 1
    if isinstance(value, (Fraction, Decimal)):
        r = ratio(value)
        return abs(r.numerator) + r.denominator - 1
    if isinstance(value, complex):
        return complexity(value.real) + complexity(value.imag)
    if isinstance(value, float):
        return struct.unpack('>Q', struct.pack('>d', abs(value)))[0]
    return abs(value)


def construct(tag, fields):
    if (tag == 'Maybe::Nothing' and not fields or
            (tag in ('Maybe::Just', 'Either::Left', 'Either::Right') and
             len(fields) == 1)):
        return DataValue(tag, fields)
    if tag == 'List::Nil' and (not fields):
        return []
    if (tag == 'List::Cons' and len(fields) == 2
            and isinstance(fields[1], list)):
        return [fields[0], *fields[1]]
    raise ValueError('invalid constructor or arity: ' + tag)


def all_elements(value, predicate):
    if not isinstance(value, list):
        raise TypeError('expected List in element predicate')
    for (index, item) in enumerate(value):
        try:
            accepted = predicate(item)
            if type(accepted) is not bool:
                raise TypeError('element predicate must return Bool')
            if not accepted:
                return False
        except Exception as error:
            raise ValueError(f'List element {index}: {error}') from error
    return True


def match_list(value, branches):
    if not isinstance(value, list):
        raise TypeError('expected List in match')
    tag = 'List::Cons' if value else 'List::Nil'
    for (candidate, branch) in branches:
        if candidate == tag:
            return branch(value[0], value[1:]) if value else branch()
    raise ValueError('missing match branch: ' + tag)


def match_value(value, branches):
    if isinstance(value, list):
        return match_list(value, branches)
    if not isinstance(value, DataValue):
        raise TypeError('expected data in match')
    arity = {
        'Maybe::Nothing': 0,
        'Maybe::Just': 1,
        'Either::Left': 1,
        'Either::Right': 1,
    }.get(value.tag, -1)
    if len(value.fields) != arity:
        raise ValueError('invalid match constructor or arity')
    for (tag, branch) in branches:
        if tag == value.tag:
            return branch(*value.fields)
    raise ValueError('missing match branch: ' + value.tag)


def either_arguments(type_key):
    """Decode a parenthesized, two-argument runtime type key."""
    args = []
    depth = 0
    start = 0
    for index in range(7, len(type_key)):
        char = type_key[index]
        if char == '(':
            if depth == 0:
                start = index + 1
            depth += 1
        elif char == ')':
            depth -= 1
            if depth < 0:
                raise ValueError('invalid Either type key')
            if depth == 0:
                args.append(type_key[start:index])
        elif depth == 0 and char != ' ':
            raise ValueError('invalid Either type key')
    if depth != 0 or len(args) != 2 or any((not arg.strip() for arg in args)):
        raise ValueError('invalid Either type key')
    return args


def integer_literal(value):
    """Decode an arbitrary integer without a host-sized intermediate."""
    return int(value)


def bytes_literal(values):
    """Construct octets without text encoding or replacement."""
    return bytes(values)


# Workflow runtime. A workflow runs under a runtime: a clock, a seeded
# random source, a trace of what happened, and the state of stateful stages.
# The runtime travels in the symbols context every generated function takes;
# without one, the default runtime applies (real time, unless the tests
# installed a virtual clock). Durations are whole microseconds.

import time as _time

_WORKFLOW = '\x00lawspec.workflow'
_MASK64 = (1 << 64) - 1


class RealClock:
    def now(self):
        return _time.monotonic_ns() // 1000

    def sleep(self, micros):
        _time.sleep(micros / 1_000_000)


class VirtualClock:
    """Sleeping advances the clock and returns at once."""

    def __init__(self, start=0):
        self.time = start

    def now(self):
        return self.time

    def sleep(self, micros):
        self.time += micros


class SplitMix64:
    """The same sequence on every target for the same seed."""

    def __init__(self, seed=0):
        self.state = seed & _MASK64

    def next(self):
        self.state = (self.state + 0x9E3779B97F4A7C15) & _MASK64
        z = self.state
        z = ((z ^ (z >> 30)) * 0xBF58476D1CE4E5B9) & _MASK64
        z = ((z ^ (z >> 27)) * 0x94D049BB133111EB) & _MASK64
        return z ^ (z >> 31)

    def below(self, bound):
        """Uniform in [0, bound); 0 when bound is 0."""
        return self.next() % bound if bound > 0 else 0


class WorkflowRuntime:
    """gates: whether rate limits, breakers, bulkheads and caches apply. The
    runtime generated tests install has them off: a workflow law calls the
    workflow and its composition, which would see each other's state."""

    def __init__(self, clock=None, seed=0, gates=True):
        self.clock = RealClock() if clock is None else clock
        self.random = SplitMix64(seed)
        self.trace = []
        self.state = {}
        self.gates = gates
        # A frame per running workflow: the undos of its completed stages.
        self.frames = []
        # When the running attempt of a stage with a timeout must end
        # (time.monotonic seconds), or None.
        self.deadline = None
        # The running attempt's stage and hedge (delay, most), or None.
        self.hedge = None

    def context(self, symbols=None):
        """A symbols context that runs workflows under this runtime."""
        symbols = {} if symbols is None else symbols
        symbols[_WORKFLOW] = self
        return symbols


_default_runtime = [None]


def use_virtual_clock(seed=0):
    """Make the default runtime virtual, as generated tests do."""
    _default_runtime[0] = WorkflowRuntime(VirtualClock(), seed, gates=False)


def workflow_runtime(symbols):
    runtime = symbols.get(_WORKFLOW) if isinstance(symbols, dict) else None
    if runtime is not None:
        return runtime
    if _default_runtime[0] is None:
        _default_runtime[0] = WorkflowRuntime()
    return _default_runtime[0]


@dataclass(frozen=True)
class Retry:
    # ('immediate',), ('fixed', d), ('linear', d, step),
    # ('exponential', d, factor, cap or None), ('fibonacci', d) or
    # ('custom', decide), where decide(attempt, error, previous) returns a
    # delay in microseconds or None to stop.
    strategy: tuple
    attempts: int
    jitter: str
    when: object = None


@dataclass(frozen=True)
class Gate:
    """A stateful policy: start(now) gives its state, admit(state, now) a
    Step of the next state and a Gate (Admit, WaitFor or Reject), and
    finish(state, now, succeeded) the state after the call. wait is None to
    fail at once when not admitted, or the most it waits (-1 for no bound)."""
    kind: str
    start: object
    admit: object
    finish: object
    wait: object = None


@dataclass(frozen=True)
class StagePolicy:
    stage: str
    retry: object = None
    timeout: object = None
    # The stage's state key, its gates (breaker, limit, bulkhead), how long
    # a success is cached (or None), and whether failures are StageFailures.
    key: str = ''
    gates: tuple = ()
    cache: object = None
    wraps: bool = False
    # Undoes the stage's success value when its workflow fails.
    compensate: object = None
    # (delay, most): when an attempt has not succeeded after delay, another
    # starts beside it, up to most in all; the first success wins.
    hedge: object = None


def _fibonacci(n):
    a, b = 1, 1
    for _ in range(n - 1):
        a, b = b, a + b
    return a


def retry_delay(strategy, attempt):
    """The delay before attempt (2 or more), before jitter."""
    kind, n = strategy[0], attempt - 1
    if kind == 'immediate':
        return 0
    if kind == 'fixed':
        return strategy[1]
    if kind == 'linear':
        return strategy[1] + strategy[2] * (n - 1)
    if kind == 'exponential':
        delay = strategy[1] * strategy[2] ** (n - 1)
        return delay if strategy[3] is None else min(delay, strategy[3])
    if kind == 'fibonacci':
        return strategy[1] * _fibonacci(n)
    raise ValueError('unknown retry strategy: ' + kind)


def jittered(jitter, delay, previous, base, random):
    """Full: [0, delay]; equal: delay/2 + [0, delay/2]; decorrelated:
    [base, previous * 3], capped at delay."""
    if jitter == 'full':
        return random.below(delay + 1)
    if jitter == 'equal':
        half = delay // 2
        return half + random.below(delay - half + 1)
    if jitter == 'decorrelated':
        high = max(base, previous * 3)
        return min(delay, base + random.below(high - base + 1))
    return delay


_STAGE_FAILURE = 'lawspec.resilience::type::StageFailure::'
_GATE = 'lawspec.resilience::type::Gate::'


def stage_failure(kind):
    return DataValue('Either::Left', (DataValue(_STAGE_FAILURE + kind, ()),))


def _pass_gate(runtime, policy, gate):
    """Admits the call or returns the failure to give instead."""
    key = policy.key + '/' + gate.kind
    waited = 0
    while True:
        now = runtime.clock.now()
        state = runtime.state.get(key)
        if state is None:
            state = gate.start(now)
        step = gate.admit(state, now)
        runtime.state[key] = step.fields[0]
        decision = step.fields[1]
        if decision.tag == _GATE + 'Admit':
            return None
        failure = {'breaker': 'CircuitOpen', 'limit': 'RateLimited', 'bulkhead': 'Saturated'}[gate.kind]
        if decision.tag == _GATE + 'Reject' or gate.wait is None:
            return failure
        delay = decision.fields[0]
        if gate.wait >= 0 and waited + delay > gate.wait:
            return failure
        runtime.trace.append(('wait', policy.stage, delay))
        runtime.clock.sleep(delay)
        waited += delay


def run_stage(symbols, policy, attempt, key=None):
    """Runs a stage's attempts under its policy; a Left is a failure.
    attempt() returns the stage's Either; key is its input, for the cache."""
    runtime = workflow_runtime(symbols)
    gates = policy.gates if runtime.gates else ()
    cached = runtime.state.setdefault(policy.key + '/cache', []) if policy.cache is not None and runtime.gates else None
    if cached is not None:
        now = runtime.clock.now()
        for entry_key, value, expires in cached:
            if now < expires and equal_values(entry_key, key):
                runtime.trace.append(('cached', policy.stage, 0))
                return value
    for gate in gates:
        failure = _pass_gate(runtime, policy, gate)
        if failure is not None:
            for passed in gates[:gates.index(gate)]:
                _finish(runtime, policy, passed, False)
            return stage_failure(failure)
    result = _attempts(runtime, policy, attempt)
    succeeded = not (isinstance(result, DataValue) and result.tag == 'Either::Left')
    for gate in gates:
        _finish(runtime, policy, gate, succeeded)
    if succeeded and policy.compensate is not None and runtime.frames:
        value = result.fields[0]
        runtime.frames[-1].append((policy.stage, lambda: policy.compensate(value)))
    if cached is not None and succeeded:
        cached[:] = [entry for entry in cached if not equal_values(entry[0], key)]
        cached.append((key, result, runtime.clock.now() + policy.cache))
    return result


def run_workflow(symbols, attempt):
    """Runs a workflow whose stages compensate: when it fails, the undos of
    its completed stages run, last first."""
    runtime = workflow_runtime(symbols)
    frame = []
    runtime.frames.append(frame)
    try:
        result = attempt()
    finally:
        runtime.frames.pop()
    if isinstance(result, DataValue) and result.tag == 'Either::Left':
        for stage, undo in reversed(frame):
            runtime.trace.append(('compensate', stage, 0))
            undo()
    return result


def _finish(runtime, policy, gate, succeeded):
    if gate.finish is not None:
        key = policy.key + '/' + gate.kind
        runtime.state[key] = gate.finish(runtime.state[key], runtime.clock.now(), succeeded)


def equal_values(a, b):
    return a == b


class StageTimedOut(Exception):
    """An attempt outlived its stage's timeout."""


def await_step(symbols, start, convert):
    """An asynchronous step's logical result: start() begins the step and
    convert turns its native result into a logical value. The step runs
    within its stage's timeout and hedge, if any."""
    runtime = workflow_runtime(symbols)
    deadline, hedge = runtime.deadline, runtime.hedge
    if deadline is None and hedge is None:
        return convert(await_task(start()))
    import asyncio

    def left():
        return None if deadline is None else max(0.0, deadline - _time.monotonic())

    async def within():
        return convert(await asyncio.wait_for(start(), left()))

    async def hedged():
        (stage, (delay, most)) = hedge
        pending, started, last = set(), 0, None

        def launch():
            nonlocal started
            started += 1
            if started > 1:
                runtime.trace.append(('hedge', stage, started))
            pending.add(asyncio.ensure_future(start()))
        launch()
        try:
            while True:
                wait = delay / 1_000_000 if started < most else None
                if deadline is not None:
                    wait = left() if wait is None else min(wait, left())
                done, _ = await asyncio.wait(pending, timeout=wait, return_when=asyncio.FIRST_COMPLETED)
                for task in done:
                    pending.discard(task)
                    value = convert(task.result())
                    if not (isinstance(value, DataValue) and value.tag == 'Either::Left'):
                        return value
                    last = value
                if deadline is not None and _time.monotonic() >= deadline:
                    raise asyncio.TimeoutError()
                if pending and done:
                    continue
                if not pending and started >= most:
                    return last
                launch()
        finally:
            for task in pending:
                task.cancel()
    try:
        return _run_blocking(within() if hedge is None else hedged())
    except asyncio.TimeoutError:
        raise StageTimedOut() from None


def _scoped(runtime, policy, attempt):
    """An attempt under its stage's timeout (failing with TimedOut when it
    outlives it) and hedge. Under the runtime generated tests install (gates
    off), both are off."""
    timeout = policy.timeout is not None and policy.timeout > 0
    if not runtime.gates or (not timeout and policy.hedge is None):
        return attempt()
    outer = (runtime.deadline, runtime.hedge)
    if timeout:
        runtime.deadline = _time.monotonic() + policy.timeout / 1_000_000
    runtime.hedge = None if policy.hedge is None else (policy.stage, policy.hedge)
    try:
        return attempt()
    except StageTimedOut:
        return stage_failure('TimedOut')
    finally:
        (runtime.deadline, runtime.hedge) = outer


def _attempts(runtime, policy, attempt):
    retry = policy.retry
    number, previous = 1, 0
    while True:
        runtime.trace.append(('start', policy.stage, number))
        result = _scoped(runtime, policy, attempt)
        failed = isinstance(result, DataValue) and result.tag == 'Either::Left'
        runtime.trace.append(('finish', policy.stage, number, not failed))
        if not failed or retry is None:
            return result
        if retry.attempts > 0 and number >= retry.attempts:
            return result
        error = result.fields[0]
        if policy.wraps:
            # Only the step's own failures and timeouts are retried.
            if error.tag == _STAGE_FAILURE + 'StepFailed':
                error = error.fields[0]
            elif error.tag != _STAGE_FAILURE + 'TimedOut':
                return result
        if retry.when is not None and not retry.when(error):
            return result
        number += 1
        if retry.strategy[0] == 'custom':
            delay = retry.strategy[1](number, error, previous)
            if delay is None:
                return result
        else:
            base = retry_delay(retry.strategy, 2) if retry.strategy[0] != 'immediate' else 0
            delay = jittered(retry.jitter, retry_delay(retry.strategy, number),
                             previous, base, runtime.random)
        runtime.trace.append(('sleep', policy.stage, delay))
        runtime.clock.sleep(delay)
        previous = delay


def retry_decision(decision):
    """A RetryDecision's delay in microseconds, or None to stop."""
    if decision.tag != 'lawspec.time::type::RetryDecision::RetryAfter':
        return None
    return decision.fields[0].fields[0]



# Portable generation for stateful models. A type descriptor is an
# s-expression: (int T lo hi) with _ for no bound, (bool), (text), (unit),
# (list D), (maybe D), (either L R), (data NAME (ctor TAG D...) ...) and
# (ref NAME) for a data type declared in the model's table. Every target
# generates, shrinks and renders the same values for the same seed.

class Quoted(str):
    """A string atom of a descriptor."""


def read_descriptor(text):
    """Parses s-expressions: lists, integers, strings, symbols and _ (None)."""
    position = [0]

    def skip():
        while position[0] < len(text) and text[position[0]] in ' \t\r\n':
            position[0] += 1

    def item():
        skip()
        c = text[position[0]]
        if c == '(':
            position[0] += 1
            items = []
            skip()
            while text[position[0]] != ')':
                items.append(item())
                skip()
            position[0] += 1
            return items
        if c == '"':
            position[0] += 1
            out = []
            while text[position[0]] != '"':
                if text[position[0]] == '\\':
                    position[0] += 1
                out.append(text[position[0]])
                position[0] += 1
            position[0] += 1
            return Quoted(''.join(out))
        start = position[0]
        while position[0] < len(text) and text[position[0]] not in ' \t\r\n()':
            position[0] += 1
        atom = text[start:position[0]]
        if atom == '_':
            return None
        if atom.lstrip('-').isdigit():
            return int(atom)
        return atom

    items = []
    skip()
    while position[0] < len(text):
        items.append(item())
        skip()
    return items


_UNBOUNDED = 1_000_000


class Values:
    """Generation, shrinking and rendering over a table of data types."""

    def __init__(self, table):
        self.table = table

    def resolve(self, d):
        return self.table[d[1]] if d[0] == 'ref' else d

    def bounds(self, d):
        """An integer's range: a missing bound is 1,000,000 from zero, or
        2,000,000 from the other bound when that is beyond it."""
        lo, hi = d[2], d[3]
        if lo is None and hi is None:
            return -_UNBOUNDED, _UNBOUNDED
        if lo is None:
            return min(-_UNBOUNDED, hi - 2 * _UNBOUNDED), hi
        if hi is None:
            return lo, max(_UNBOUNDED, lo + 2 * _UNBOUNDED)
        return lo, hi

    def base(self, d):
        """The constructors whose fields mention no data type."""
        found = [c for c in d[2:] if not any(_mentions_data(f) for f in c[2:])]
        return found or d[2:]

    def generate(self, d, random, size):
        d = self.resolve(d)
        kind = d[0]
        if kind == 'int':
            lo, hi = self.bounds(d)
            if random.below(10) < 2:
                specials = [lo, hi, min(max(0, lo), hi), min(max(1, lo), hi)]
                return specials[random.below(4)]
            return lo + random.below(hi - lo + 1)
        if kind == 'bool':
            return random.below(2) == 1
        if kind == 'text':
            return ''.join(chr(32 + random.below(95)) for _ in range(random.below(size + 1)))
        if kind == 'unit':
            return UNIT
        if kind == 'list':
            return [self.generate(d[1], random, size) for _ in range(random.below(size + 1))]
        if kind == 'maybe':
            if random.below(4) == 0:
                return DataValue('Maybe::Nothing', ())
            return DataValue('Maybe::Just', (self.generate(d[1], random, size),))
        if kind == 'either':
            if random.below(2) == 0:
                return DataValue('Either::Left', (self.generate(d[1], random, size),))
            return DataValue('Either::Right', (self.generate(d[2], random, size),))
        if kind == 'data':
            choices = self.base(d) if size <= 0 else d[2:]
            ctor = choices[random.below(len(choices))]
            return DataValue(str(ctor[1]), tuple(self.generate(f, random, max(size - 1, 0)) for f in ctor[2:]))
        raise ValueError('unknown descriptor ' + str(d))

    def minimal(self, d):
        d = self.resolve(d)
        kind = d[0]
        if kind == 'int':
            lo, hi = self.bounds(d)
            return min(max(0, lo), hi)
        if kind == 'bool':
            return False
        if kind == 'text':
            return ''
        if kind == 'unit':
            return UNIT
        if kind == 'list':
            return []
        if kind == 'maybe':
            return DataValue('Maybe::Nothing', ())
        if kind == 'either':
            return DataValue('Either::Left', (self.minimal(d[1]),))
        ctor = self.base(d)[0]
        return DataValue(str(ctor[1]), tuple(self.minimal(f) for f in ctor[2:]))

    def shrink(self, d, v):
        """Smaller candidates for v, most aggressive first."""
        d = self.resolve(d)
        kind = d[0]
        out = []
        if kind == 'int':
            target = self.minimal(d)
            if v != target:
                out = [target, v - _toward_zero(v - target, 2), v - (1 if v > target else -1)]
        elif kind == 'bool':
            out = [False] if v else []
        elif kind == 'text':
            if v:
                out = [''] + [v[:len(v) // 2]] + [v[:i] + v[i + 1:] for i in range(len(v))]
        elif kind == 'list':
            if v:
                out = [[]] + [v[:len(v) // 2]] + [v[:i] + v[i + 1:] for i in range(len(v))]
                for i, item in enumerate(v):
                    out += [v[:i] + [c] + v[i + 1:] for c in self.shrink(d[1], item)]
        elif kind == 'maybe':
            if v.tag == 'Maybe::Just':
                out = [DataValue('Maybe::Nothing', ())] + [DataValue('Maybe::Just', (c,)) for c in self.shrink(d[1], v.fields[0])]
        elif kind == 'either':
            inner = d[1] if v.tag == 'Either::Left' else d[2]
            out = [DataValue(v.tag, (c,)) for c in self.shrink(inner, v.fields[0])]
        elif kind == 'data':
            ctor = next(c for c in d[2:] if str(c[1]) == v.tag)
            out = [self.minimal(d)]
            # A field of the same type is a smaller value of it.
            out += [f for f, fd in zip(v.fields, ctor[2:]) if fd == ['ref', d[1]]]
            for i, (field, fd) in enumerate(zip(v.fields, ctor[2:])):
                out += [DataValue(v.tag, v.fields[:i] + (c,) + v.fields[i + 1:]) for c in self.shrink(fd, field)]
        seen, unique = [], []
        for c in out:
            if not _same(c, v) and not any(_same(c, s) for s in seen):
                seen.append(c)
                unique.append(c)
        return unique


def _toward_zero(n, d):
    q = abs(n) // d
    return q if n >= 0 else -q


def _mentions_data(d):
    return isinstance(d, list) and (d[0] in ('ref', 'data') or any(_mentions_data(x) for x in d[1:]))


def _same(a, b):
    return render(a) == render(b)


def render(v):
    """A value's canonical text, the same on every target."""
    if isinstance(v, bool):
        return 'true' if v else 'false'
    if isinstance(v, int):
        return str(v)
    if isinstance(v, str):
        return '"' + v.replace('\\', '\\\\').replace('"', '\\"') + '"'
    if v is UNIT:
        return '()'
    if isinstance(v, (list, tuple)):
        return '[' + ', '.join(render(x) for x in v) + ']'
    if isinstance(v, DataValue):
        name = v.tag.split('::')[-1]
        return name if not v.fields else name + '(' + ', '.join(render(x) for x in v.fields) + ')'
    return str(v)


def values_from(text):
    """A descriptor text's data types and its last form, the one generated."""
    forms = read_descriptor(text)
    table = {str(f[1]): f for f in forms if isinstance(f, list) and f[0] == 'data'}
    return Values(table), forms[-1]


def generated(text, seed, size, count):
    """count values generated from one SplitMix64 seed, rendered."""
    values, d = values_from(text)
    random = SplitMix64(seed)
    return [render(values.generate(d, random, size)) for _ in range(count)]


def shrunk(text, seed, size):
    """The shrink candidates of the first value generated, rendered."""
    values, d = values_from(text)
    return [render(c) for c in values.shrink(d, values.generate(d, SplitMix64(seed), size))]
