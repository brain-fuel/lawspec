// LawSpec scalar runtime. No test framework dependencies.
export class Rational {
  constructor(n, d = 1n) {
    n = BigInt(n); d = BigInt(d);
    if (!d) throw new RangeError('exact division by zero');
    if (d < 0n) { n = -n; d = -d; }
    let a = n < 0n ? -n : n, b = d;
    while (b) [a,b] = [b,a%b];
    this.n = n/a; this.d = d/a;
    Object.freeze(this);
  }
  toString() { return `${this.n}/${this.d}`; }
}
export class Decimal {
  constructor(coefficient, exponent = 0n) { this.coefficient = BigInt(coefficient); this.exponent = BigInt(exponent); Object.freeze(this); }
  toString() { return `${this.coefficient}e${this.exponent}`; }
}
export class Complex {
  constructor(real, imaginary) { this.real = real; this.imaginary = imaginary; Object.freeze(this); }
}
export class Raw {
  constructor(kind, units) { this.kind = kind; this.units = Object.freeze([...units]); Object.freeze(this); }
}
export class Presence {
  constructor(kind, present, value) { this.kind = kind; this.present = present; this.value = value; Object.freeze(this); }
}
export const UNIT = Object.freeze({kind:'Unit'});
export const integerType = t => /^(U?Int(8|16|32|64|Size)|UIntPtr|BigU?Int|Integer)$/.test(t);
export const exactType = t => integerType(t) || ['Decimal','Rational'].includes(t);
export function ratio(x) {
  if (x instanceof Rational) return x;
  if (x instanceof Decimal) return x.exponent >= 0n ? new Rational(x.coefficient*10n**x.exponent) : new Rational(x.coefficient,10n**-x.exponent);
  if (typeof x === 'bigint') return new Rational(x);
  if (typeof x === 'number' && Number.isInteger(x)) return new Rational(BigInt(x));
  throw new TypeError('exact numeric value required');
}
export function bounds(t,bits=64) {
  if ((t === 'BigInt' || t === 'Integer')) return [null,null];
  if (t === 'BigUInt') return [0n,null];
  const w = BigInt(['IntSize','UIntSize','UIntPtr'].includes(t) ? bits : t.match(/\d+/)[0]);
  return t.startsWith('U') ? [0n,2n**w-1n] : [-(2n**(w-1n)),2n**(w-1n)-1n];
}
function decimal(x) {
  const r=ratio(x); let d=r.d,a=0n,b=0n;
  while(d%2n===0n){d/=2n;a++;} while(d%5n===0n){d/=5n;b++;}
  if(d!==1n) throw new RangeError('Decimal conversion is not finite; use round');
  const scale=a>b?a:b;
  return new Decimal(r.n*2n**(scale-a)*5n**(scale-b),-scale);
}
export function convert(x,t,bits=64) {
  if(integerType(t)) {
    const r = typeof x === 'number' && Number.isFinite(x) ? floatRatio(x) : ratio(x);
    if(r.d!==1n) throw new RangeError('fractional conversion to '+t);
    const [lo,hi]=bounds(t,bits);
    if((lo!==null&&r.n<lo)||(hi!==null&&r.n>hi)) throw new RangeError('integer outside '+t+' range');
    return ['Int8','Int16','Int32','UInt8','UInt16','UInt32'].includes(t) ? Number(r.n) : r.n;
  }
  if(t==='Rational') return typeof x === 'number' ? floatRatio(x) : ratio(x);
  if(t==='Decimal') return decimal(typeof x === 'number' ? floatRatio(x) : x);
  if(t==='Float32'||t==='Float64') {
    let v;
    if(typeof x === 'number') v=x;
    else v=exactFloat(ratio(x),t);
    return t==='Float32'?Math.fround(v):v;
  }
  if(t==='Complex64'||t==='Complex128') { const z=x instanceof Complex?x:new Complex(convert(x,t==='Complex64'?'Float32':'Float64'),0); return t==='Complex64'?new Complex(Math.fround(z.real),Math.fround(z.imaginary)):z; }
  return validate(x,t,bits);
}
function floatRatio(x) {
  if(!Number.isFinite(x)) throw new RangeError('non-finite exact conversion');
  if(x===0) return new Rational(0n);
  const a=new DataView(new ArrayBuffer(8)); a.setFloat64(0,x);
  const bits=a.getBigUint64(0), sign=bits>>63n?-1n:1n;
  const exp=(bits>>52n)&2047n, mant=(bits&((1n<<52n)-1n))+(exp?1n<<52n:0n), shift=(exp||1n)-1075n;
  return shift>=0?new Rational(sign*mant*2n**shift):new Rational(sign*mant,2n**-shift);
}
function validUnit(t,c) {
  return Number.isInteger(c)&&c>=0&&c<=(t==='Bytes'?255:['Utf16Text','CodeUnit16'].includes(t)?65535:1114111)&&(!['Text','Char'].includes(t)||c<55296||c>57343);
}
export function validate(x,t,bits=64) {
  const fail=()=>{throw new TypeError('invalid '+t+' value');};
  if(t.startsWith('Nullable ')||t.startsWith('Optional ')) {
    const i=t.indexOf(' '),kind=t.slice(0,i);
    if(!(x instanceof Presence)||x.kind!==kind||typeof x.present!=='boolean') fail();
    if(x.present) return new Presence(kind,true,validate(x.value,t.slice(i+1),bits));
  } else if(integerType(t)) {
    if(!['number','bigint'].includes(typeof x)||(typeof x==='number'&&!Number.isSafeInteger(x))) fail();
    return convert(x,t,bits);
  } else if(t==='Bool') { if(typeof x!=='boolean') fail(); }
  else if(t==='Text'||t==='Char') { if(typeof x!=='string'||(t==='Char'&&[...x].length!==1)||![...x].every(c=>validUnit(t,c.codePointAt(0)))) fail(); }
  else if(t==='CodePoint'||t==='CodeUnit16') { if(!validUnit(t,x)) fail(); }
  else if(t==='Bytes') { if(!(x instanceof Uint8Array)) fail(); return new Uint8Array(x); }
  else if(['Utf16Text','CodePointText'].includes(t)) { if(!(x instanceof Raw)||x.kind!==t||!x.units.every(c=>validUnit(t,c))) fail(); }
  else if(t==='Symbol') { if(typeof x!=='symbol') fail(); }
  else if(t==='Unit') { if(x!==UNIT) fail(); }
  else if(t==='Null') { if(x!==null) fail(); }
  else if(t==='Undefined') { if(x!==undefined) fail(); }
  else if(t==='Decimal') { if(!(x instanceof Decimal)) fail(); }
  else if(t==='Rational') { if(!(x instanceof Rational)) fail(); }
  else if(t.startsWith('Float')) { if(typeof x!=='number'||(t==='Float32'&&!Number.isNaN(x)&&Math.fround(x)!==x)) fail(); }
  else if(t.startsWith('Complex')) { if(!(x instanceof Complex)) fail(); validate(x.real,t==='Complex64'?'Float32':'Float64'); validate(x.imaginary,t==='Complex64'?'Float32':'Float64'); }
  else fail();
  return x;
}
export function literal(v,symbols=new Map()) {
  const t=v.type;
  if(integerType(t)) return convert(BigInt(v.value),t);
  if(t==='Bool') return v.value;
  if(t==='Decimal') return new Decimal(v.coefficient,v.exponent);
  if(t==='Rational') return new Rational(v.numerator,v.denominator);
  if(t.startsWith('Float')) {const a=new DataView(new ArrayBuffer(8)); if(t==='Float32'){a.setUint32(0,Number.parseInt(v.bits,16));return a.getFloat32(0);} a.setBigUint64(0,BigInt('0x'+v.bits)); return a.getFloat64(0);}
  if(t.startsWith('Complex')) return new Complex(literal(v.real),literal(v.imaginary));
  if(t==='Text') return v.units.map(c=>String.fromCodePoint(c)).join('');
  if(t==='Char') return String.fromCodePoint(v.value);
  if(t==='CodePoint'||t==='CodeUnit16') return v.value;
  if(t==='Bytes'){if(!v.units.every(c=>validUnit(t,c)))throw new RangeError('invalid Bytes');return new Uint8Array(v.units);}
  if(['CodePointText','Utf16Text'].includes(t)) return new Raw(t,v.units);
  if(t==='Symbol'){if(!symbols.has(v.id)) symbols.set(v.id,Symbol(v.description));return symbols.get(v.id);}
  if(t==='Nullable'||t==='Optional') return new Presence(t,v.value!==null,v.value===null?undefined:literal(v.value,symbols));
  if(t==='Null') return null;
  if(t==='Undefined') return undefined;
  return UNIT;
}
export function promote(a,b,op) {
  if(exactType(a)!==exactType(b)) throw new TypeError('exact/inexact mixing requires explicit conversion');
  if(exactType(a)) return op==='/'||[a,b].includes('Rational')?'Rational':[a,b].includes('Decimal')?'Decimal':'Integer';
  if(a.startsWith('Complex')||b.startsWith('Complex')) return [a,b].some(t=>['Float64','Complex128'].includes(t))?'Complex128':'Complex64';
  return [a,b].includes('Float64')?'Float64':'Float32';
}
export function binary(op,a,b,ta,tb) {
  if((op==='=='||op==='!=')&&!exactType(ta)&&!['Float32','Float64','Complex64','Complex128'].includes(ta)){const result=equal(a,b,ta,tb);return op==='=='?result:!result;}
  const t=promote(ta,tb,op);
  if(exactType(ta)) {
    a=ratio(a); b=ratio(b);
    const x=a.n*b.d,y=b.n*a.d;
    if(['==','!=','<','<=','>','>='].includes(op)) return compare(op,x,y);
    let r;
    if(op==='+')r=new Rational(x+y,a.d*b.d);
    else if(op==='-')r=new Rational(x-y,a.d*b.d);
    else if(op==='*')r=new Rational(a.n*b.n,a.d*b.d);
    else if(op==='/')r=new Rational(a.n*b.d,a.d*b.n);
    else if(op==='quot'||op==='rem'){if(a.d!==1n||b.d!==1n)throw new TypeError('integer operands required');return op==='quot'?a.n/b.n:a.n%b.n;}
    else throw new Error('unknown operator '+op);
    return convert(r,t);
  }
  if(t.startsWith('Complex')) {
    a=convert(a,t);b=convert(b,t); const r=t==='Complex64'?Math.fround:x=>x;
    if(op==='=='||op==='!='){const e=a.real===b.real&&a.imaginary===b.imaginary;return op==='=='?e:!e;}
    if(op==='+')return new Complex(r(a.real+b.real),r(a.imaginary+b.imaginary));
    if(op==='-')return new Complex(r(a.real-b.real),r(a.imaginary-b.imaginary));
    if(op==='*')return new Complex(r(r(a.real*b.real)-r(a.imaginary*b.imaginary)),r(r(a.real*b.imaginary)+r(a.imaginary*b.real)));
    if(op==='/'){const d=r(r(b.real*b.real)+r(b.imaginary*b.imaginary));return new Complex(r(r(r(a.real*b.real)+r(a.imaginary*b.imaginary))/d),r(r(r(a.imaginary*b.real)-r(a.real*b.imaginary))/d));}
  }
  if(['==','!=','<','<=','>','>='].includes(op))return compare(op,a,b);
  const v=op==='+'?a+b:op==='-'?a-b:op==='*'?a*b:a/b;
  return t==='Float32'?Math.fround(v):v;
}
function compare(op,a,b){return op==='=='?a===b:op==='!='?a!==b:op==='<'?a<b:op==='<='?a<=b:op==='>'?a>b:a>=b;}
export function equal(a,b,ta,tb) {
  if(ta==='Bytes'&&tb==='Bytes')return a.length===b.length&&a.every((c,i)=>c===b[i]);
  if(['Float32','Float64','Complex64','Complex128'].includes(ta)&&['Float32','Float64','Complex64','Complex128'].includes(tb))return binary('==',a,b,ta,tb);
  if(exactType(ta)&&exactType(tb)){a=ratio(a);b=ratio(b);return a.n===b.n&&a.d===b.d;}
  if(a instanceof Complex&&b instanceof Complex)return a.real===b.real&&a.imaginary===b.imaginary;
  if(a instanceof Presence&&b instanceof Presence)return a.kind===b.kind&&a.present===b.present&&(!a.present||equal(a.value,b.value,ta.slice(ta.indexOf(' ')+1),tb.slice(tb.indexOf(' ')+1)));
  if(a instanceof Raw&&b instanceof Raw)return a.kind===b.kind&&a.units.length===b.units.length&&a.units.every((c,i)=>c===b.units[i]);
  return a===b;
}
export function helper(n,args,types,bits=64){
  const x=args[0];
  if(n==='checked')return true;
  if(n==='length')return BigInt(typeof x==='string'?[...x].length:x instanceof Raw?x.units.length:x.length);
  if(n==='isPresent')return x.present;
  if(n==='presentValue'){if(!x.present)throw new Error('absent presence value');return x.value;}

  if(n==='real')return x.real;
  if(n==='imag')return x.imaginary;
  if(n==='negate'){if(exactType(types[0]))return binary('-',0n,x,'BigInt',types[0]);return x instanceof Complex?new Complex(-x.real,-x.imaginary):-x;}
  if(n==='quot'||n==='rem')return binary(n,...args,...types);
  if(n==='isNaN')return Number.isNaN(x);
  if(n==='isInfinite')return x===Infinity||x===-Infinity;
  if(n==='isFinite')return Number.isFinite(x);
  if(n==='isNegativeZero')return Object.is(x,-0);
  if(n==='round'){
    const scale=BigInt(convert(args[1],'Int32',bits)),factor=scale>=0n?new Rational(10n**scale):new Rational(1n,10n**-scale),v=ratio(x),a=new Rational(v.n*factor.n,v.d*factor.d);
    let q=a.n/a.d,r=a.n%a.d;const abs=r<0n?-r:r;
    if(abs*2n>a.d||(abs*2n===a.d&&q%2n!==0n))q+=a.n<0n?-1n:1n;
    return decimal(new Rational(q*factor.d,factor.n));
  }
  return convert(x,n,bits);
}

// Round an exact rational directly to IEEE precision, including subnormal ties.
function exactFloat(r,t) {
  if(r.n===0n)return 0;
  const negative=r.n<0n,n=negative?-r.n:r.n,d=r.d,single=t==='Float32';
  const p=single?24:53,bias=single?127:1023,emin=1-bias,emax=bias;
  let e=n.toString(2).length-d.toString(2).length;
  if(e>=0?n<(d<<BigInt(e)):(n<<BigInt(-e))<d)e--;
  if(e>emax)return negative?-Infinity:Infinity;
  const scale=Math.max(e,emin)-(p-1);
  const num=scale<0?n<<BigInt(-scale):n,den=scale>0?d<<BigInt(scale):d;
  let q=num/den,rem=num%den;
  if(rem*2n>den||(rem*2n===den&&q%2n!==0n))q++;
  e=Math.max(e,emin);
  if(q===(1n<<BigInt(p))){q>>=1n;e++;}
  if(e>emax)return negative?-Infinity:Infinity;
  const hidden=1n<<BigInt(p-1),exponent=q<hidden?0:e+bias,mantissa=q<hidden?q:q-hidden;
  const bits=(BigInt(negative?1:0)<<BigInt(single?31:63))|(BigInt(exponent)<<BigInt(p-1))|mantissa;
  const view=new DataView(new ArrayBuffer(8));
  if(single){view.setUint32(0,Number(bits));return view.getFloat32(0);}
  view.setBigUint64(0,bits);return view.getFloat64(0);
}

export function unitResult(value) { return value === undefined ? UNIT : validate(value, "Unit"); }

// Domain generation operates on exact values independently of test frameworks.
export function sample(t,seed,bits=64) {
  let n=BigInt(seed);const next=()=>n=BigInt.asUintN(256,n*6364136223846793005n+1442695040888963407n);
  for(let j=0;j<8;j++)next();
  if(t.startsWith('Nullable ')||t.startsWith('Optional ')){const [kind,...rest]=t.split(' ');return new Presence(kind,!!(seed%2),seed%2?sample(rest.join(' '),Math.trunc(seed/2),bits):undefined);}
  if(integerType(t)){let [lo,hi]=bounds(t,bits);lo??=-(2n**256n);hi??=2n**256n;return convert(lo+n%(hi-lo+1n),t,bits);}
  if(t==='Bool')return !!(seed%2);
  if(t==='Decimal')return new Decimal(n-2n**255n,BigInt(seed%41-20));
  if(t==='Rational')return new Rational(n-2n**255n,next()%2n**128n+1n);
  if(t.startsWith('Float'))return literal({type:t,bits:BigInt.asUintN(t==='Float32'?32:64,n).toString(16).padStart(t==='Float32'?8:16,'0')});
  if(t.startsWith('Complex')){const c=t==='Complex64'?'Float32':'Float64';return new Complex(sample(c,seed,bits),sample(c,seed+1,bits));}
  if(t==='Unit')return UNIT;if(t==='Null')return null;if(t==='Undefined')return undefined;if(t==='Symbol')return Symbol('same');
  const maximum=t==='Bytes'?256:['Utf16Text','CodeUnit16'].includes(t)?65536:1114112;
  const unit=()=>{let c;do{c=Number(next()%BigInt(maximum));}while(['Char','Text'].includes(t)&&c>=55296&&c<=57343);return c;};
  if(t==='Char')return String.fromCodePoint(unit());if(['CodePoint','CodeUnit16'].includes(t))return unit();
  const xs=Array.from({length:Number(n%40n)},unit);
  if(t==='Text')return String.fromCodePoint(...xs);if(t==='Bytes')return new Uint8Array(xs);return new Raw(t,xs);
}
const floorRatio=r=>r.n/r.d-(r.n<0n&&r.n%r.d!==0n?1n:0n);
const ceilRatio=r=>-floorRatio(new Rational(-r.n,r.d));
export function domainCandidates(t,seed,bits,restrictions,hints) {
  let candidates=[];for(const hint of hints){try{candidates.push(convert(hint,t,bits));}catch{}}
  if(integerType(t)) {
    let [lo,hi]=bounds(t,bits);
    for(const [op,value] of restrictions){const r=ratio(value);
      if(['>','>=','=='].includes(op)){const v=op==='>'?floorRatio(r)+1n:ceilRatio(r);lo=lo===null||v>lo?v:lo;}
      if(['<','<=','=='].includes(op)){const v=op==='<'?ceilRatio(r)-1n:floorRatio(r);hi=hi===null||v<hi?v:hi;}
    }
    if(lo!==null&&hi!==null&&lo>hi)return [];
    const lower=lo??((hi??0n)<0n?(hi??0n)-2n**256n:-(2n**256n)),upper=hi??((lo??0n)>0n?(lo??0n)+2n**256n:2n**256n);
    candidates.push(lower,upper,0n,1n,-1n,lower+1n,upper-1n);
    let n=BigInt(seed);for(let j=0;j<8;j++){n=BigInt.asUintN(256,n*6364136223846793005n+1442695040888963407n);candidates.push(lower+n%(upper-lower+1n));}
    candidates=candidates.filter(v=>['number','bigint'].includes(typeof v)&&BigInt(v)>=lower&&BigInt(v)<=upper).map(v=>convert(v,t,bits));
  } else for(let j=0;j<8;j++)candidates.push(sample(t,seed+j*7919,bits));
  if(candidates.length){const offset=((seed%candidates.length)+candidates.length)%candidates.length;candidates=[...candidates.slice(offset),...candidates.slice(0,offset)];}
  return candidates;
}
export function generateTuple(domains,seed,attempts,prefix=[]) {
  let used=0,lastPrefix=prefix;
  const search=values=>{lastPrefix=values;if(values.length===domains.length)return values;if(used>=attempts)return null;used++;
    const [candidates,accept]=domains[values.length];
    for(const value of candidates(values,seed+used*7919)){if(used>=attempts)break;used++;const next=[...values,value];if(accept(next)){const result=search(next);if(result!==null)return result;}}
    return null;
  };
  while(used<attempts){const result=search([...prefix]);if(result!==null)return result;}
  throw new Error(`refinement-generation-exhausted after ${used} attempts; prefix=${lastPrefix.map(String)}; seed=${seed}`);
}
export function requireContract(condition,context){if(condition!==true)throw new Error(context);}
export function refinedCase(domains,seed,attempts,shrinks,check,context="refinement") {
  let values;try{values=generateTuple(domains,seed,attempts);}catch(error){throw new Error(`${context}: ${error.message}`,{cause:error});}
  try{check(values);}catch(original){let best=values,budget=shrinks;
    for(let i=0;i<best.length;i++){
      const current=best[i],integer=typeof current==='bigint'||typeof current==='number'&&Number.isSafeInteger(current);
      const candidates=domains[i][0](best.slice(0,i),0);
      if(integer){const initial=BigInt(current);let reduced=initial;candidates.unshift(typeof current==='number'?0:0n,typeof current==='number'?Math.sign(current):initial>0n?1n:-1n);
        while(reduced>1n||reduced< -1n){reduced/=2n;candidates.splice(2,0,typeof current==='number'?Number(reduced):reduced);}}
      for(const candidate of candidates){if(budget--<=0)break;if(complexity(candidate)>=complexity(best[i]))continue;
        const prefix=[...best.slice(0,i),candidate];if(!domains[i][1](prefix))continue;
        let trial;try{trial=generateTuple(domains,seed,Math.min(attempts,100),prefix);}catch(error){if(error.message.startsWith('refinement-generation-exhausted'))continue;throw error;}
        try{check(trial);}catch{best=trial;}
      }
    }
    throw new Error(`${context}: ${original.message}; refined counterexample=${best.map(String)}; seed=${seed}`,{cause:original});
  }
}

function complexity(value){
  if(value instanceof Presence)return value.present?1n+complexity(value.value):0n;
  if(value instanceof Raw)return BigInt(value.units.length);
  if(value instanceof Uint8Array)return BigInt(value.length);
  if(typeof value==='string')return BigInt([...value].length);
  if(typeof value==='bigint')return value<0n?-value:value;
  if(typeof value==='number'){if(Number.isSafeInteger(value))return BigInt(Math.abs(value));const view=new DataView(new ArrayBuffer(8));view.setFloat64(0,Math.abs(value));return view.getBigUint64(0);}
  if(typeof value==='boolean')return value?1n:0n;
  if(value instanceof Decimal||value instanceof Rational){const r=ratio(value);return (r.n<0n?-r.n:r.n)+r.d-1n;}
  if(value instanceof Complex)return complexity(value.real)+complexity(value.imaginary);
  if(typeof value==='symbol')return 1n;
  return 0n;
}
