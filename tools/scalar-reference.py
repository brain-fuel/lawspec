"""Independent exact conformance oracle. Uses only Python's standard Fraction."""
import json
from fractions import Fraction
from pathlib import Path
from random import Random
rng = Random(701)
vectors = []
def put(expression, value):
    r = Fraction(value)
    vectors.append({'expression':expression,'expected':f'rational({r.numerator}, {r.denominator})'})
for _ in range(8):
    a,b = rng.randrange(-2**100,2**100),rng.randrange(1,2**80)
    for op, result in [('+',a+b),('-',a-b),('*',a*b),('/',Fraction(a,b))]:
        put(f'({a}) {op} ({b})',result)
    q = abs(a)//b * (-1 if a < 0 else 1)
    put(f'prelude.quot ({a}) ({b})', q)
    put(f'prelude.rem ({a}) ({b})',a-q*b)
for c,e,scale in [(125,-2,1),(135,-2,1),(-125,-2,1),(-135,-2,1),(150,0,-2),(250,0,-2),(999999999999999999999999999999,-20,6)]:
    x=Fraction(c)*Fraction(10)**e
    factor=Fraction(10)**scale
    put(f'prelude.round decimal({c}, {e}) ({scale})', Fraction(round(x*factor),1)/factor)
put('0.1 + 0.2', Fraction(3,10))
put('decimal(123456789012345678901234567890, -30) * 0.1',Fraction(123456789012345678901234567890,10**31))
(root := Path(__file__).resolve().parent.parent / 'test' / 'scalar-vectors.json').write_text(json.dumps(vectors,indent=2)+'\n')
print(f'{len(vectors)} independent exact vectors: {root}')
