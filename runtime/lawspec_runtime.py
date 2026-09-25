"""LawSpec scalar runtime. Independent of property and assertion frameworks."""
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

@dataclass(frozen=True)
class Raw:
    kind: str
    units: tuple

    def __post_init__(self):
        object.__setattr__(self, "units", tuple(self.units))

@dataclass(eq=False, frozen=True)
class Symbol:
    description: str

@dataclass(frozen=True)
class Absence:
    kind: str

UNIT, NULL, UNDEFINED = (Absence(t) for t in ('Unit', 'Null', 'Undefined'))

def integer_type(t):
    return t.startswith(('Int', 'UInt')) or t in ('BigInt', 'BigUInt')

def exact_type(t):
    return integer_type(t) or t in ('Decimal', 'Rational')

def bounds(t, bits=64):
    if t in ('Integer', 'BigInt', 'BigUInt'):
        return (0 if t == 'BigUInt' else None), None
    width = bits if t in ('IntSize', 'UIntSize', 'UIntPtr') else int(t[4:] if t.startswith('UInt') else t[3:])
    return (0, 2**width-1) if t.startswith('U') else (-2**(width-1), 2**(width-1)-1)

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
    d, a, b = r.denominator, 0, 0
    while d % 2 == 0:
        d //= 2
        a += 1
    while d % 5 == 0:
        d //= 5
        b += 1
    if d != 1:
        raise ValueError('Decimal conversion is not finite; use round')
    scale = max(a, b)
    c = r.numerator * 2**(scale-a) * 5**(scale-b)
    return Decimal((int(c < 0), tuple(map(int, integer_text(abs(c)))), -scale))

def convert(x, t, bits=64):
    if integer_type(t):
        r = ratio(x)
        if r.denominator != 1:
            raise ValueError('fractional conversion to ' + t)
        x = r.numerator
        lo, hi = bounds(t, bits)
        if (lo is not None and x < lo) or (hi is not None and x > hi):
            raise ValueError('integer outside ' + t + ' range')
        return x
    if t == 'Rational':
        return ratio(x)
    if t == 'Decimal':
        return finite_decimal(x)
    if t in ('Float32', 'Float64'):
        if not isinstance(x,float): return exact_float(ratio(x),t)
        try:
            v = float(x)
        except OverflowError:
            v = math.copysign(math.inf, -1 if x < 0 else 1)
        return f32(v) if t == 'Float32' else v
    if t in ('Complex64', 'Complex128'):
        z = x if isinstance(x,complex) else complex(convert(x,'Float32' if t == 'Complex64' else 'Float64'),0)
        return complex(f32(z.real), f32(z.imag)) if t == 'Complex64' else z
    return validate(x, t, bits)

def valid_unit(t, c):
    maximum = 255 if t == 'Bytes' else 65535 if t in ('Utf16Text','CodeUnit16') else 1114111
    return type(c) is int and 0 <= c <= maximum and (t not in ('Text','Char') or not 55296 <= c <= 57343)

def validate(x, t, bits=64):
    if t.startswith(('Nullable ', 'Optional ')):
        k, inner = t.split(' ', 1)
        if not isinstance(x, Presence) or x.kind != k or type(x.present) is not bool:
            raise ValueError('tagged presence required for ' + t)
        if x.present:
            validate(x.value, inner, bits)
    elif integer_type(t):
        if type(x) is not int:
            raise ValueError('integer required for ' + t)
        convert(x, t, bits)
    elif t == 'Bool':
        if type(x) is not bool:
            raise ValueError('Bool required')
    elif t in ('Text','Char'):
        if not isinstance(x, str) or (t == 'Char' and len(x) != 1) or not all(valid_unit(t, ord(c)) for c in x):
            raise ValueError('invalid ' + t)
    elif t in ('CodePoint', 'CodeUnit16'):
        if not valid_unit(t, x):
            raise ValueError('invalid ' + t)
    elif t == 'Bytes':
        if type(x) is not bytes: raise ValueError('Bytes required')
    elif t in ('CodePointText','Utf16Text'):
        if not isinstance(x, Raw) or x.kind != t or not all(valid_unit(t,c) for c in x.units):
            raise ValueError('invalid ' + t)
    elif t in ('Unit','Null','Undefined'):
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
    elif t in ('Float32','Float64'):
        if type(x) is not float or (t == 'Float32' and not math.isnan(x) and f32(x) != x):
            raise ValueError('invalid ' + t)
    elif t in ('Complex64','Complex128'):
        if type(x) is not complex:
            raise ValueError('complex required')
        if t == 'Complex64':
            validate(x.real,'Float32'); validate(x.imag,'Float32')
    else:
        raise ValueError('unknown scalar type ' + t)
    return x

def literal(v, symbols=None):
    t = v['type']
    if integer_type(t): return parse_integer(v['value'])
    if t == 'Bool': return v['value']
    if t == 'Decimal':
        c = parse_integer(v['coefficient'])
        return Decimal((int(c < 0), tuple(map(int,integer_text(abs(c)))), int(v['exponent'])))
    if t == 'Rational': return Fraction(parse_integer(v['numerator']),parse_integer(v['denominator']))
    if t.startswith('Float'): return struct.unpack('>f' if t == 'Float32' else '>d', bytes.fromhex(v['bits']))[0]
    if t.startswith('Complex'): return complex(literal(v['real']),literal(v['imaginary']))
    if t == 'Text': return ''.join(map(chr,v['units']))
    if t == 'Char': return chr(v['value'])
    if t in ('CodePoint','CodeUnit16'): return v['value']
    if t == 'Bytes': return bytes(v['units'])
    if t in ('CodePointText','Utf16Text'): return Raw(t,tuple(v['units']))
    if t == 'Symbol':
        if symbols is None: symbols = {}
        return symbols.setdefault(v['id'],Symbol(v['description']))
    if t in ('Nullable','Optional'): return Presence(t,v['value'] is not None,literal(v['value'],symbols) if v['value'] is not None else None)
    return Absence(t)

def promote(a,b,op):
    if exact_type(a) != exact_type(b): raise ValueError('exact/inexact mixing requires explicit conversion')
    if exact_type(a): return 'Rational' if op == '/' or 'Rational' in (a,b) else 'Decimal' if 'Decimal' in (a,b) else 'Integer'
    if a.startswith('Complex') or b.startswith('Complex'): return 'Complex128' if a in ('Float64','Complex128') or b in ('Float64','Complex128') else 'Complex64'
    return 'Float64' if 'Float64' in (a,b) else 'Float32'

def ieee_div(a,b):
    if b != 0: return a / b
    if a == 0 or math.isnan(a): return math.nan
    return math.copysign(math.inf, math.copysign(1,a) * math.copysign(1,b))

def binary(op,a,b,ta,tb):
    if op in ('==','!=') and not exact_type(ta) and ta not in ('Float32','Float64','Complex64','Complex128'):
        result = equal(a,b,ta,tb)
        return result if op == '==' else not result
    t = promote(ta,tb,op)
    if exact_type(ta): a,b = ratio(a),ratio(b)
    elif t.startswith('Complex'):
        a,b = complex(a),complex(b)
        rnd = f32 if t == 'Complex64' else float
        if op == '+': return complex(rnd(a.real+b.real),rnd(a.imag+b.imag))
        if op == '-': return complex(rnd(a.real-b.real),rnd(a.imag-b.imag))
        if op == '*': return complex(rnd(rnd(a.real*b.real)-rnd(a.imag*b.imag)),rnd(rnd(a.real*b.imag)+rnd(a.imag*b.real)))
        if op == '/':
            d = rnd(rnd(b.real*b.real)+rnd(b.imag*b.imag))
            return complex(rnd(ieee_div(rnd(rnd(a.real*b.real)+rnd(a.imag*b.imag)),d)),rnd(ieee_div(rnd(rnd(a.imag*b.real)-rnd(a.real*b.imag)),d)))
    if op in ('quot','rem'):
        q = abs(a.numerator)//abs(b.numerator)
        if (a < 0) != (b < 0): q = -q
        return q if op == 'quot' else a.numerator-q*b.numerator
    if op in ('<','<=','>','>=','==','!='):
        return {'<':lambda:a<b,'<=':lambda:a<=b,'>':lambda:a>b,'>=':lambda:a>=b,'==':lambda:a==b,'!=':lambda:a!=b}[op]()
    if op == '+': v = a+b
    elif op == '-': v = a-b
    elif op == '*': v = a*b
    elif op == '/': v = a/b if exact_type(ta) else ieee_div(a,b)
    else: raise ValueError('unknown operation '+op)
    return convert(v,t)

def equal(a,b,ta,tb):
    if exact_type(ta) and exact_type(tb): return ratio(a) == ratio(b)
    if isinstance(a,Presence) and isinstance(b,Presence):
        return a.kind == b.kind and a.present == b.present and (not a.present or equal(a.value,b.value,ta.split(' ',1)[1],tb.split(' ',1)[1]))
    if isinstance(a,complex) and isinstance(b,complex): return a.real == b.real and a.imag == b.imag
    return a == b

def helper(n,args,types,bits=64):
    x = args[0]
    if n == 'checked': return True
    if n == 'length': return len(x.units) if isinstance(x, Raw) else len(x)
    if n == 'isPresent': return x.present
    if n == 'presentValue':
        if not x.present: raise ValueError('absent presence value')
        return x.value
    if n == 'real': return x.real
    if n == 'imag': return x.imag
    if n == 'negate':
        if exact_type(types[0]): return binary('-',0,x,'BigInt',types[0])
        return convert(-x,types[0])
    if n in ('quot','rem'): return binary(n,*args,*types)
    if n == 'isNaN': return math.isnan(x)
    if n == 'isInfinite': return math.isinf(x)
    if n == 'isFinite': return math.isfinite(x)
    if n == 'isNegativeZero': return x == 0 and math.copysign(1,x) < 0
    if n == 'round':
        scale = convert(args[1],'Int32',bits)
        factor = Fraction(10**scale) if scale >= 0 else Fraction(1,10**(-scale))
        return finite_decimal(Fraction(round(ratio(x)*factor),1)/factor)
    return convert(x,n,bits)

def make_decimal(c, e):
    return Decimal((int(c < 0), tuple(map(int, integer_text(abs(c)))), e))

def exact_float(r, t):
    if not r: return 0.0
    negative = r < 0
    n, d = abs(r.numerator), r.denominator
    single = t == 'Float32'
    p, bias = (24, 127) if single else (53, 1023)
    emin, emax = 1-bias, bias
    e = n.bit_length() - d.bit_length()
    if (n < d << e) if e >= 0 else (n << -e < d): e -= 1
    if e > emax: return -math.inf if negative else math.inf
    scale = max(e, emin) - (p-1)
    num, den = (n << -scale if scale < 0 else n), (d << scale if scale > 0 else d)
    q, rem = divmod(num, den)
    if 2*rem > den or (2*rem == den and q % 2): q += 1
    e = max(e, emin)
    if q == 1 << p: q >>= 1; e += 1
    if e > emax: return -math.inf if negative else math.inf
    hidden = 1 << (p-1)
    exponent = 0 if q < hidden else e+bias
    mantissa = q if q < hidden else q-hidden
    bits = (int(negative) << (31 if single else 63)) | (exponent << (p-1)) | mantissa
    return struct.unpack('>f' if single else '>d',bits.to_bytes(4 if single else 8,'big'))[0]

def parse_integer(text):
    negative = text.startswith('-')
    text = text.lstrip('+-')
    if not text or not text.isascii() or not text.isdigit():
        raise ValueError('invalid integer representation')
    result = 0
    for start in range(0,len(text),9):
        chunk = text[start:start+9]
        result = result * 10**len(chunk) + int(chunk)
    return -result if negative else result

def integer_text(value):
    if value == 0: return '0'
    negative, value = value < 0, abs(value)
    chunks = []
    while value:
        value, rest = divmod(value,1_000_000_000)
        chunks.append(rest)
    return ('-' if negative else '') + str(chunks[-1]) + ''.join(f'{n:09d}' for n in reversed(chunks[:-1]))

def unit_result(value):
    return UNIT if value is None else validate(value, "Unit")

# Dependent-domain operations contain no assertion-framework dependencies.
def sample(t, seed, bits=64):
    import random
    r = random.Random(seed)
    if t.startswith(('Nullable ', 'Optional ')):
        kind, inner = t.split(' ', 1)
        return Presence(kind, bool(seed % 2), sample(inner, seed//2, bits) if seed % 2 else None)
    if integer_type(t):
        lo, hi = bounds(t, bits)
        return r.randint(lo if lo is not None else -(2**256), hi if hi is not None else 2**256)
    if t == 'Bool': return bool(seed % 2)
    if t == 'Decimal': return make_decimal(r.randint(-(2**128), 2**128), r.randint(-20,20))
    if t == 'Rational': return Fraction(r.randint(-(2**128), 2**128), r.randint(1,2**128))
    if t.startswith('Float'): return literal({'type':t,'bits':format(r.getrandbits(32 if t=='Float32' else 64),'08x' if t=='Float32' else '016x')})
    if t.startswith('Complex'):
        c = 'Float32' if t=='Complex64' else 'Float64'
        return complex(sample(c,seed,bits),sample(c,seed+1,bits))
    if t in ('Unit','Null','Undefined'): return {'Unit':UNIT,'Null':NULL,'Undefined':UNDEFINED}[t]
    if t == 'Symbol': return Symbol('same')
    maximum = 255 if t=='Bytes' else 65535 if t in ('Utf16Text','CodeUnit16') else 1114111
    def unit():
        while True:
            c=r.randint(0,maximum)
            if t not in ('Text','Char') or not 55296<=c<=57343: return c
    if t == 'Char': return chr(unit())
    if t in ('CodePoint','CodeUnit16'): return unit()
    units = tuple(unit() for _ in range(r.randint(0,39)))
    if t == 'Text': return ''.join(map(chr,units))
    if t == 'Bytes': return bytes(units)
    return Raw(t,units)

def domain_candidates(t, seed, bits, restrictions, hints):
    candidates = []
    for hint in hints:
        try: candidates.append(convert(hint,t,bits))
        except (ValueError,TypeError,OverflowError): pass
    if integer_type(t):
        lo, hi = bounds(t,bits)
        for op, value in restrictions:
            r=ratio(value)
            if op in ('>','>=','=='):
                bound=math.floor(r)+1 if op=='>' else math.ceil(r)
                lo=bound if lo is None else max(lo,bound)
            if op in ('<','<=','=='):
                bound=math.ceil(r)-1 if op=='<' else math.floor(r)
                hi=bound if hi is None else min(hi,bound)
        if lo is not None and hi is not None and lo>hi: return []
        lower=lo if lo is not None else min(-(2**256),(hi or 0)-2**256)
        upper=hi if hi is not None else max(2**256,(lo or 0)+2**256)
        candidates += [lower, upper, 0, 1, -1, lower+1, upper-1]
        import random
        r=random.Random(seed)
        candidates += [r.randint(lower,upper) for _ in range(8)]
        candidates=[v for v in candidates if isinstance(v,int) and not isinstance(v,bool) and lower<=v<=upper]
    else:
        candidates += [sample(t,seed+j*7919,bits) for j in range(8)]
    if candidates:
        offset=seed % len(candidates)
        candidates=candidates[offset:]+candidates[:offset]
    return candidates

def generate_tuple(domains, seed, attempts, prefix=()):
    used=0
    last_prefix=list(prefix)
    def search(values):
        nonlocal used, last_prefix
        last_prefix=values
        if len(values)==len(domains): return values
        if used>=attempts: return None
        used+=1
        candidates, accept = domains[len(values)]
        for value in candidates(values,seed+used*7919):
            if used>=attempts: break
            used+=1
            next_values=values+[value]
            if accept(next_values):
                result=search(next_values)
                if result is not None: return result
        return None
    while used<attempts:
        result=search(list(prefix))
        if result is not None: return result
    raise ValueError(f'refinement-generation-exhausted after {used} attempts; prefix={last_prefix!r}; seed={seed}')

def require_contract(condition, context):
    if condition is not True: raise ValueError(context)

def refined_case(domains, seed, attempts, shrinks, check, context="refinement"):
    try: values=generate_tuple(domains,seed,attempts)
    except Exception as error: raise ValueError(f"{context}: {error}") from error
    try: check(values)
    except Exception as original:
        best=values
        budget=shrinks
        for index in range(len(best)):
            value=best[index]
            candidates=domains[index][0](best[:index],0)
            if isinstance(value,int) and not isinstance(value,bool):
                candidates=[0, 1 if value>0 else -1]+candidates
                reduced=value
                while abs(reduced)>1:
                    reduced=abs(reduced)//2 * (1 if reduced>0 else -1)
                    candidates.insert(2,reduced)
            for candidate in candidates:
                if budget<=0: break
                budget-=1
                if complexity(candidate)>=complexity(best[index]): continue
                prefix=best[:index]+[candidate]
                if not domains[index][1](prefix): continue
                try: trial=generate_tuple(domains,seed,min(attempts,100),prefix)
                except ValueError as error:
                    if str(error).startswith('refinement-generation-exhausted'): continue
                    raise
                try: check(trial)
                except Exception: best=trial
        raise AssertionError(f'{context}: {original}; refined counterexample={best!r}; seed={seed}') from original

def complexity(value):
    if isinstance(value,Presence): return 1+complexity(value.value) if value.present else 0
    if isinstance(value,Raw): return len(value.units)
    if isinstance(value,(str,bytes)): return len(value)
    if isinstance(value,Absence): return 0
    if isinstance(value,Symbol): return 1
    if isinstance(value,(Fraction,Decimal)):
        r=ratio(value); return abs(r.numerator)+r.denominator-1
    if isinstance(value,complex): return complexity(value.real)+complexity(value.imag)
    if isinstance(value,float): return struct.unpack('>Q',struct.pack('>d',abs(value)))[0]
    return abs(value)
