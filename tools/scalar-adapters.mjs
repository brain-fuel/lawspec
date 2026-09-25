// Correct implementations and adversarial replacements for the scalar bridge suite.
export function implementScalarAdapter(target, source) {
 if(target==='rust') {
  const bodies={successor:'ls::BigInt::from(value0) + 1',addDecimal:'value0.add(&value1).unwrap()',sameSymbol:'value0 == value1',finish:'()'};
  return source.replace(/(pub fn (\w+)\([^\n]+?\{) todo!\([^\n]+?\) }/g,(_,prefix,name)=>`${prefix} ${bodies[name]||'value0'} }`);
 }

 const js=target==='javascript'||target==='typescript';
 const bodies={
  javascript:{preserveBig:'return value0;',machineEcho:'return value0;',successor:'return BigInt(value0) + 1n;',narrow:'return value0;',addDecimal:"return ls.binary('+', value0, value1, 'Decimal', 'Decimal');",sameSymbol:'return value0 === value1;',echoRaw:'return value0;',echoPresence:'return value0;',finish:'return;'},
  python:{preserveBig:'return value0',machineEcho:'return value0',successor:'return value0 + 1',narrow:'return value0',addDecimal:'return ls.finite_decimal(ls.ratio(value0) + ls.ratio(value1))',sameSymbol:'return value0 is value1',echoRaw:'return value0',echoPresence:'return value0',finish:'return None'},
  java:{preserveBig:'return value0;',machineEcho:'return value0;',successor:'return java.math.BigInteger.valueOf(value0).add(java.math.BigInteger.ONE);',narrow:'return value0;',addDecimal:'return value0.add(value1);',sameSymbol:'return LawSpecRuntime.equal(value0, value1);',echoRaw:'return value0;',echoPresence:'return value0;',finish:'return;'},
  kotlin:{preserveBig:'value0',machineEcho:'value0',successor:'java.math.BigInteger.valueOf(value0.toLong() + 1)',narrow:'value0',addDecimal:'value0.add(value1)',sameSymbol:'LawSpecRuntime.equal(value0, value1)',echoRaw:'value0',echoPresence:'value0',finish:'Unit'},
  go:{preserveBig:'return value0',machineEcho:'return value0',successor:'return new(LawSpecBigInt).SetInt64(int64(value0) + 1)',narrow:'return value0',addDecimal:'return lsBinary("+", value0, value1)',sameSymbol:'return lsEqual(value0, value1)',echoRaw:'return value0',echoPresence:'return value0',finish:'return'},
  haskell:{preserveBig:'value0',machineEcho:'value0',successor:'toInteger value0 + 1',narrow:'value0',addDecimal:'LS.binary "+" value0 value1',sameSymbol:'LS.equal value0 value1',echoRaw:'value0',echoPresence:'value0',finish:'()'},
 }[js?'javascript':target];
 for(const name of ['echoChar','echoCodePoint','echoCodeUnit','echoBytes','echoComplex'])bodies[name]=target==='haskell'||target==='kotlin'?'value0':target==='java'||js?'return value0;':'return value0';
 if(js){source=`import * as ls from '../lawspec_runtime.${target==='typescript'?'js':'mjs'}';\n`+source;for(const [n,body] of Object.entries(bodies)) source=source.replace(new RegExp(`(export function ${n}\\([^\\n]+?\\{) throw new Error\\([^\\n]+?; }`),`$1 ${body} }`);}
 if(target==='python')for(const [n,body] of Object.entries(bodies))source=source.replace(new RegExp(`(def ${n}\\([^\\n]+\\n)    raise NotImplementedError\\([^\\n]+`),`$1    ${body}`);
 if(target==='java')for(const [n,body] of Object.entries(bodies))source=source.replace(new RegExp(`(public static [^\\n]+ ${n}\\([^\\n]+?\\{) throw new UnsupportedOperationException\\([^\\n]+?; }`),`$1 ${body} }`);
 if(target==='kotlin')for(const [n,body] of Object.entries(bodies))source=source.replace(new RegExp(`(fun ${n}\\([^\\n]+? = )TODO\\([^\\n]+`),`$1${body}`);
 if(target==='go')for(const [n,body] of Object.entries(bodies)){const cap=n[0].toUpperCase()+n.slice(1);source=source.replace(new RegExp(`(func ${cap}\\([^\\n]+?\\{) panic\\([^\\n]+? }`),`$1 ${body} }`);}
 if(target==='haskell'){source=source.replace(/import LawSpecRuntime \([^\n]+\)/,'$&\nimport qualified LawSpecRuntime as LS');for(const [n,body] of Object.entries(bodies))source=source.replace(new RegExp(`^${n} ([_ ]+) = error [^\\n]+`,'m'),(_,args)=>`${n} ${args.trim().split(/ +/).map((_,i)=>'value'+i).join(' ')} = ${body}`);}
 if(/TODO\(|NotImplementedError\(|UnsupportedOperationException\(|throw new Error\(|panic\(| = error /.test(source))throw new Error('Unimplemented scalar adapter: '+target+'\n'+source);
 return source;
}
export function overflowMutant(target,source){
 const changes={javascript:['BigInt(value0) + 1n','BigInt((value0 + 1) << 24 >> 24)'],typescript:['BigInt(value0) + 1n','BigInt((value0 + 1) << 24 >> 24)'],python:['return value0 + 1','return (value0 + 129) % 256 - 128'],java:['java.math.BigInteger.valueOf(value0).add(java.math.BigInteger.ONE)','java.math.BigInteger.valueOf((byte)(value0 + 1))'],kotlin:['java.math.BigInteger.valueOf(value0.toLong() + 1)','java.math.BigInteger.valueOf((value0 + 1).toByte().toLong())'],go:['int64(value0) + 1','int64(value0 + 1)'],haskell:['toInteger value0 + 1','toInteger (value0 + 1)']};
 const [a,b]=changes[target];if(!source.includes(a))throw new Error('Missing mutant marker');return source.replace(a,b);
}
export function scalarMutants(target,source) {
 if(target==='rust') {
  const bodies={successor:'ls::BigInt::from(value0.wrapping_add(1))',preserveBig:'(value0 as f64) as u64',addDecimal:'ls::Decimal::round(value0.ratio().unwrap() + value1.ratio().unwrap(), 0).unwrap()',echoRaw:'ls::Utf16Text(vec![65533])',echoPresence:'ls::Optional::Undefined',sameSymbol:'value0.description() == value1.description()'};
  return Object.entries(bodies).map(([name,body])=>({name,content:source.replace(new RegExp(`(pub fn ${name}\\([^\\n]+?\\{)[^\\n]+? }`),`$1 ${body} }`)}));
 }

 const js=target==='javascript'||target==='typescript';
 const expressions={
  javascript:{preserveBig:'return BigInt(Number(value0));',addDecimal:"return ls.helper('round',[ls.binary('+',value0,value1,'Decimal','Decimal'),0],['Decimal','Int32']);",echoRaw:"return new ls.Raw('Utf16Text',[65533]);",echoPresence:"return new ls.Presence('Optional',false);",sameSymbol:'return value0.description === value1.description;'},
  python:{preserveBig:'return int(float(value0))',addDecimal:'return value0 + value1',echoRaw:'return ls.Raw("Utf16Text",(65533,))',echoPresence:'return ls.Presence("Optional",False)',sameSymbol:'return value0.description == value1.description'},
  java:{preserveBig:'return java.math.BigInteger.valueOf((long)value0.doubleValue());',addDecimal:'return value0.add(value1, new java.math.MathContext(3));',echoRaw:'return String.valueOf((char)65533);',echoPresence:'return LawSpecRuntime.convert("Optional Nullable Int8",LawSpecRuntime.absent("Undefined"),64);',sameSymbol:'return ((LawSpecRuntime.SymbolValue)value0.data()).description().equals(((LawSpecRuntime.SymbolValue)value1.data()).description());'},
  kotlin:{preserveBig:'java.math.BigInteger.valueOf(value0.toDouble().toLong())',addDecimal:'value0.add(value1,java.math.MathContext(3))',echoRaw:'65533.toChar().toString()',echoPresence:'LawSpecRuntime.convert("Optional Nullable Int8",LawSpecRuntime.absent("Undefined"),64)',sameSymbol:'(value0.data() as LawSpecRuntime.SymbolValue).description() == (value1.data() as LawSpecRuntime.SymbolValue).description()'},
  go:{preserveBig:'return uint64(float64(value0))',addDecimal:'return lsHelper("round",[]LawSpecValue{lsBinary("+",value0,value1),lsInteger("Int32","0")},64)',echoRaw:'return []uint16{65533}',echoPresence:'return lsConvert("Optional Nullable Int8",lsAbsent("Undefined"),64)',sameSymbol:'return value0.Data.(*lawSpecSymbol).description == value1.Data.(*lawSpecSymbol).description'},
  haskell:{preserveBig:'round (fromIntegral value0 :: Double)',addDecimal:'LS.helper "round" [LS.binary "+" value0 value1,LS.SInteger "Int32" 0] 64',echoRaw:'LS.SSequence "Utf16Text" [65533]',echoPresence:'LS.SPresent "Optional" Nothing',sameSymbol:'case (value0,value1) of (LS.SSymbol _ a,LS.SSymbol _ b) -> a == b; _ -> False'},
 }[js?'javascript':target];
 return [{name:'overflow',content:overflowMutant(target,source)},...Object.entries(expressions).map(([n,body])=>{
  let result;
  if(js)result=source.replace(new RegExp(`(export function ${n}\\([^\n]+?\\{)[^\n]+? }`),`$1 ${body} }`);
  else if(target==='python')result=source.replace(new RegExp(`(def ${n}\\([^\n]+\n)    [^\n]+`),`$1    ${body}`);
  else if(target==='java')result=source.replace(new RegExp(`(public static [^\n]+ ${n}\\([^\n]+?\\{)[^\n]+? }`),`$1 ${body} }`);
  else if(target==='kotlin')result=source.replace(new RegExp(`(fun ${n}\\([^\n]+? = )[^\n]+`),`$1${body}`);
  else if(target==='go')result=source.replace(new RegExp(`(func ${n[0].toUpperCase()+n.slice(1)}\\([^\n]+?\\{)[^\n]+? }`),`$1 ${body} }`);
  else result=source.replace(new RegExp(`^(${n} [^\n]+? = )[^\n]+`,'m'),`$1${body}`);
  if(result===source)throw new Error('Mutant did not change source: '+target+'/'+n);
  return {name:n,content:result};
 })];
}
