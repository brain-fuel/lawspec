package lawspec.runtime;

import java.math.BigInteger;
import java.math.BigDecimal;
import java.math.RoundingMode;
import java.util.*;

/** Portable scalars and arithmetic, independent of test frameworks. */
public final class LawSpecRuntime {
  private LawSpecRuntime() {}
  public record Value(String type, Object data) {}
  public record Complex(double real, double imaginary) {}
  public record SymbolValue(String description) {}
  public record Presence(boolean present, Value value) {}
  public record Ratio(BigInteger n, BigInteger d) {
    public Ratio {
      if (d.signum() == 0) throw new ArithmeticException("exact division by zero");
      if (d.signum() < 0) { n=n.negate(); d=d.negate(); }
      var gcd=n.gcd(d); n=n.divide(gcd); d=d.divide(gcd);
    }
  }
  public static boolean integerType(String t) { return t.matches("(U?Int(8|16|32|64|Size)|UIntPtr|BigU?Int|Integer)"); }
  public static boolean exactType(String t) { return integerType(t)||t.equals("Decimal")||t.equals("Rational"); }
  public static Value integer(String t,String n) { return new Value(t,new BigInteger(n)); }
  public static Value decimal(String c,String e) { return new Value("Decimal", new BigDecimal(new BigInteger(c),Math.negateExact(Integer.parseInt(e)))); }
  public static Value rational(String n,String d) { return new Value("Rational",new Ratio(new BigInteger(n),new BigInteger(d))); }
  public static Value bool(boolean b) { return new Value("Bool",b); }
  public static Value floating(String t,String bits) { return new Value(t,t.equals("Float32")?(double)Float.intBitsToFloat(Integer.parseUnsignedInt(bits,16)):Double.longBitsToDouble(Long.parseUnsignedLong(bits,16))); }
  public static Value complex(String t,Value r,Value i) { return new Value(t,new Complex((double)r.data,(double)i.data)); }
  public static Value sequence(String t,int[] units) { return new Value(t,Arrays.stream(units).boxed().toList()); }
  public static Value character(String t,int c) { return new Value(t,c); }
  public static Value absent(String t) { return new Value(t,null); }
  public static Value present(String t,Value v) { return new Value(t,new Presence(v!=null,v)); }
  public static Value symbol(String id,String description,Map<String,Object> symbols) { return new Value("Symbol",symbols.computeIfAbsent(id,k->new SymbolValue(description))); }
  private static Ratio ratio(Value v) {
    if(integerType(v.type))return new Ratio((BigInteger)v.data,BigInteger.ONE);
    if(v.data instanceof Ratio r)return r;
    if(v.data instanceof BigDecimal d){int s=d.scale();return new Ratio(s<0?d.unscaledValue().multiply(BigInteger.TEN.pow(-s)):d.unscaledValue(),s<0?BigInteger.ONE:BigInteger.TEN.pow(s));}
    throw new IllegalArgumentException("exact numeric value required");
  }
  private static double real(Value v) {
    if(v.data instanceof Double d)return d;
    Ratio r=ratio(v);
    return new BigDecimal(r.n).divide(new BigDecimal(r.d),new java.math.MathContext(400,RoundingMode.HALF_EVEN)).doubleValue();
  }
  private static double precision(String t,double d){return t.equals("Float32")||t.equals("Complex64")?(double)(float)d:d;}
  public static Value convert(String t,Value v,int bits) {
    if(t.startsWith("Nullable ")||t.startsWith("Optional ")) {
      int i=t.indexOf(' ');String k=t.substring(0,i);
      if(v.type.equals(k.equals("Nullable")?"Null":"Undefined"))return new Value(t,new Presence(false,null));
      if(v.data instanceof Presence p)return new Value(t,new Presence(p.present,p.present?convert(t.substring(i+1),p.value,bits):null));
      throw new IllegalArgumentException("tagged presence required");
    }
    if(integerType(t)) {
      Ratio r=v.data instanceof Double d?ratio(new Value("Decimal",new BigDecimal(d))):ratio(v);
      if(!r.d.equals(BigInteger.ONE))throw new ArithmeticException("fractional conversion to "+t);
      if(!t.equals("BigInt")&&!t.equals("Integer")) {
        if(t.startsWith("U")||t.equals("BigUInt")){if(r.n.signum()<0)throw new ArithmeticException("integer outside "+t+" range");}
        if(!t.equals("BigUInt")){
          int w=t.endsWith("Size")||t.equals("UIntPtr")?bits:Integer.parseInt(t.replaceAll("\\D",""));boolean signed=t.startsWith("Int");
          BigInteger hi=BigInteger.ONE.shiftLeft(signed?w-1:w).subtract(BigInteger.ONE),lo=signed?BigInteger.ONE.shiftLeft(w-1).negate():BigInteger.ZERO;
          if(r.n.compareTo(lo)<0||r.n.compareTo(hi)>0)throw new ArithmeticException("integer outside "+t+" range");
        }
      }
      return new Value(t,r.n);
    }
    if(t.equals("Rational")||t.equals("Decimal")) {
      Ratio r=v.data instanceof Double d?ratio(new Value("Decimal",new BigDecimal(d))):ratio(v);
      return new Value(t,t.equals("Rational")?r:new BigDecimal(r.n).divide(new BigDecimal(r.d)));
    }
    if(t.startsWith("Float"))return new Value(t,exactType(v.type)?exactFloat(ratio(v),t.equals("Float32")):precision(t,real(v)));
    if(t.startsWith("Complex")){Complex c=v.data instanceof Complex z?z:new Complex((double)convert(t.equals("Complex64")?"Float32":"Float64",v,bits).data,0);return new Value(t,new Complex(precision(t,c.real),precision(t,c.imaginary)));}
    if(!t.equals(v.type))throw new IllegalArgumentException("cannot convert "+v.type+" to "+t);
    return validate(t,v,bits);
  }
  private static boolean validUnit(String t,int c){return c>=0&&c<=(t.equals("Bytes")?255:t.equals("Utf16Text")||t.equals("CodeUnit16")?65535:1114111)&&(!(t.equals("Char")||t.equals("Text"))||c<55296||c>57343);}
  public static Value validate(String t,Value v,int bits) {
    if(v==null&&t.equals("Unit"))return absent("Unit");
    if(v==null||!v.type.equals(t))throw new IllegalArgumentException("invalid "+t+" representation");
    if(integerType(t))return convert(t,v,bits);
    Object data=v.data;
    boolean valid;
    if(t.startsWith("Nullable ")||t.startsWith("Optional ")){valid=data instanceof Presence;if(valid){Presence p=(Presence)data;if(p.present)validate(t.substring(t.indexOf(' ')+1),p.value,bits);}}
    else if(List.of("Text","CodePointText","Utf16Text","Bytes").contains(t)){valid=data instanceof List<?>;if(valid)for(Object x:(List<?>)data)if(!(x instanceof Integer c)||!validUnit(t,c))valid=false;}
    else if(List.of("Char","CodePoint","CodeUnit16").contains(t))valid=data instanceof Integer c&&validUnit(t,c);
    else if(t.equals("Bool"))valid=data instanceof Boolean;
    else if(t.equals("Decimal"))valid=data instanceof BigDecimal;
    else if(t.equals("Rational"))valid=data instanceof Ratio;
    else if(t.startsWith("Float"))valid=data instanceof Double d&&(t.equals("Float64")||Double.isNaN(d)||(double)(float)d.doubleValue()==d);
    else if(t.startsWith("Complex")){valid=data instanceof Complex;if(valid){Complex c=(Complex)data;String component=t.equals("Complex64")?"Float32":"Float64";validate(component,new Value(component,c.real),bits);validate(component,new Value(component,c.imaginary),bits);}}
    else if(t.equals("Symbol"))valid=data instanceof SymbolValue;
    else valid=List.of("Unit","Null","Undefined").contains(t)&&data==null;
    if(!valid)throw new IllegalArgumentException("invalid "+t+" representation");
    if(data instanceof List<?> xs)return new Value(t,List.copyOf(xs));
    if(data instanceof Presence p&&p.present)return new Value(t,new Presence(true,validate(t.substring(t.indexOf(' ')+1),p.value,bits)));
    return v;
  }
  private static String promote(String a,String b,String op) {
    if(exactType(a)!=exactType(b))throw new IllegalArgumentException("exact/inexact mixing requires explicit conversion");
    if(exactType(a))return op.equals("/")||a.equals("Rational")||b.equals("Rational")?"Rational":a.equals("Decimal")||b.equals("Decimal")?"Decimal":"Integer";
    if(a.startsWith("Complex")||b.startsWith("Complex"))return a.equals("Float64")||b.equals("Float64")||a.equals("Complex128")||b.equals("Complex128")?"Complex128":"Complex64";
    return a.equals("Float64")||b.equals("Float64")?"Float64":"Float32";
  }
  private static boolean compare(String op,int c){return switch(op){case "=="->c==0;case "!="->c!=0;case "<"->c<0;case "<="->c<=0;case ">"->c>0;case ">="->c>=0;default->throw new IllegalArgumentException(op);};}
  public static Value binary(String op,Value a,Value b) {
    if((op.equals("==")||op.equals("!="))&&!exactType(a.type)&&!a.type.startsWith("Float")&&!a.type.startsWith("Complex"))return bool(op.equals("==")==equal(a,b));
    String t=promote(a.type,b.type,op);
    if(exactType(a.type)) {
      Ratio x=ratio(a),y=ratio(b);BigInteger p=x.n.multiply(y.d),q=y.n.multiply(x.d),d=x.d.multiply(y.d);
      if(List.of("==","!=","<","<=",">",">=").contains(op))return bool(compare(op,p.compareTo(q)));
      if(op.equals("quot")||op.equals("rem")){if(!x.d.equals(BigInteger.ONE)||!y.d.equals(BigInteger.ONE))throw new IllegalArgumentException("integer required");return new Value("Integer",op.equals("quot")?x.n.divide(y.n):x.n.remainder(y.n));}
      Ratio r=switch(op){case "+"->new Ratio(p.add(q),d);case "-"->new Ratio(p.subtract(q),d);case "*"->new Ratio(x.n.multiply(y.n),d);case "/"->new Ratio(x.n.multiply(y.d),x.d.multiply(y.n));default->throw new IllegalArgumentException(op);};
      return convert(t,new Value("Rational",r),64);
    }
    if(t.startsWith("Complex")) {
      Complex x=(Complex)convert(t,a,64).data,y=(Complex)convert(t,b,64).data;double re,im;
      if(op.equals("==")||op.equals("!="))return bool(op.equals("==")== (x.real==y.real&&x.imaginary==y.imaginary));
      if(op.equals("+")){re=x.real+y.real;im=x.imaginary+y.imaginary;}
      else if(op.equals("-")){re=x.real-y.real;im=x.imaginary-y.imaginary;}
      else if(op.equals("*")){re=precision(t,x.real*y.real)-precision(t,x.imaginary*y.imaginary);im=precision(t,x.real*y.imaginary)+precision(t,x.imaginary*y.real);}
      else {double d=precision(t,precision(t,y.real*y.real)+precision(t,y.imaginary*y.imaginary));re=precision(t,precision(t,x.real*y.real)+precision(t,x.imaginary*y.imaginary))/d;im=precision(t,precision(t,x.imaginary*y.real)-precision(t,x.real*y.imaginary))/d;}
      return new Value(t,new Complex(precision(t,re),precision(t,im)));
    }
    double x=real(a),y=real(b);
    if(List.of("==","!=","<","<=",">",">=").contains(op))return bool(switch(op){case "=="->x==y;case "!="->x!=y;case "<"->x<y;case "<="->x<=y;case ">"->x>y;default->x>=y;});
    return new Value(t,precision(t,switch(op){case "+"->x+y;case "-"->x-y;case "*"->x*y;case "/"->x/y;default->throw new IllegalArgumentException(op);}));
  }
  public static boolean equal(Value a,Value b) {
    if((a.type.startsWith("Float")||a.type.startsWith("Complex"))&&(b.type.startsWith("Float")||b.type.startsWith("Complex")))return truth(binary("==",a,b));
    if(exactType(a.type)&&exactType(b.type))return ratio(a).equals(ratio(b));
    if(a.data instanceof Double x&&b.data instanceof Double y)return x.doubleValue()==y.doubleValue();
    if(a.data instanceof Complex x&&b.data instanceof Complex y)return x.real==y.real&&x.imaginary==y.imaginary;
    if(a.data instanceof Presence x&&b.data instanceof Presence y)return a.type.equals(b.type)&&x.present==y.present&&(!x.present||equal(x.value,y.value));
    if(a.type.equals("Symbol"))return a.data==b.data;
    return a.type.equals(b.type)&&Objects.equals(a.data,b.data);
  }
  public static boolean truth(Value v){return (boolean)validate("Bool",v,64).data;}
  public static Value helper(String n,Value[] args,int bits) {
    if(n.equals("checked"))return bool(true);
    if(n.equals("length"))return integer("Integer",Integer.toString(((List<?>)args[0].data).size()));
    if(n.equals("isPresent"))return bool(((Presence)args[0].data).present);
    if(n.equals("presentValue")){Presence p=(Presence)args[0].data;if(!p.present)throw new IllegalArgumentException("absent presence value");return p.value;}

    Value x=args[0];
    if(n.equals("real")||n.equals("imag")){Complex c=(Complex)x.data;return new Value(x.type.equals("Complex64")?"Float32":"Float64",n.equals("real")?c.real:c.imaginary); }
    if(n.equals("quot")||n.equals("rem"))return binary(n,x,args[1]);
    if(n.equals("negate")){if(exactType(x.type))return binary("-",integer("BigInt","0"),x);if(x.data instanceof Complex c)return new Value(x.type,new Complex(-c.real,-c.imaginary));return new Value(x.type,-real(x));}
    if(n.equals("isNaN"))return bool(Double.isNaN(real(x)));
    if(n.equals("isInfinite"))return bool(Double.isInfinite(real(x)));
    if(n.equals("isFinite"))return bool(Double.isFinite(real(x)));
    if(n.equals("isNegativeZero"))return bool(Double.doubleToRawLongBits(real(x))==Long.MIN_VALUE);
    if(n.equals("round")){Ratio r=ratio(x);int scale=((BigInteger)convert("Int32",args[1],bits).data).intValueExact();return new Value("Decimal",new BigDecimal(r.n).divide(new BigDecimal(r.d),scale,RoundingMode.HALF_EVEN));}
    return convert(n,x,bits);
  }

  public static Value sample(String t,int seed,int bits) {
    Random random=new Random(seed);
    if(t.startsWith("Nullable ")||t.startsWith("Optional ")){int i=t.indexOf(' ');return new Value(t,new Presence(random.nextBoolean(),sample(t.substring(i+1),random.nextInt(),bits)));}
    if(integerType(t)){
      if(t.equals("Integer")||t.equals("BigInt")||t.equals("BigUInt")){BigInteger n=new BigInteger(256,random);return new Value(t,(t.equals("BigInt")||t.equals("Integer"))&&random.nextBoolean()?n.negate():n);}
      int w=t.endsWith("Size")||t.equals("UIntPtr")?bits:Integer.parseInt(t.replaceAll("\\D",""));BigInteger n=new BigInteger(w,random);if(t.startsWith("Int")&&n.testBit(w-1))n=n.subtract(BigInteger.ONE.shiftLeft(w));return new Value(t,n);
    }
    if(t.equals("Bool"))return bool(random.nextBoolean());
    if(t.equals("Decimal"))return new Value(t,new BigDecimal(new BigInteger(128,random),random.nextInt(41)-20));
    if(t.equals("Rational"))return new Value(t,new Ratio(new BigInteger(128,random).subtract(BigInteger.ONE.shiftLeft(127)),new BigInteger(128,random).add(BigInteger.ONE)));
    if(t.startsWith("Float"))return new Value(t,t.equals("Float32")?(double)Float.intBitsToFloat(random.nextInt()):Double.longBitsToDouble(random.nextLong()));
    if(t.startsWith("Complex")){String component=t.equals("Complex64")?"Float32":"Float64";return complex(t,sample(component,random.nextInt(),bits),sample(component,random.nextInt(),bits));}
    if(t.equals("Symbol"))return new Value(t,new SymbolValue("same"));
    if(List.of("Unit","Null","Undefined").contains(t))return absent(t);
    int max=t.equals("Bytes")?256:t.equals("CodeUnit16")||t.equals("Utf16Text")?65536:1114112;
    if(List.of("Char","CodePoint","CodeUnit16").contains(t)){int c;do{c=random.nextInt(max);}while(!validUnit(t,c));return character(t,c);}
    int[] xs=new int[random.nextInt(40)];for(int j=0;j<xs.length;j++){do{xs[j]=random.nextInt(max);}while(!validUnit(t,xs[j]));}return sequence(t,xs);
  }

  public static Value unit(Runnable operation) { operation.run(); return absent("Unit"); }
  public static Object toNative(String t,Value v,int bits) {
    v=convert(t,v,bits);
    if(integerType(t)){BigInteger n=(BigInteger)v.data;return switch(t){case "Int8"->n.byteValueExact();case "Int16","UInt8"->n.shortValueExact();case "Int32","UInt16"->n.intValueExact();case "Int64","UInt32"->n.longValueExact();default->n;};}
    if(t.equals("Char"))return new String(Character.toChars((int)v.data));
    if(t.equals("CodePoint"))return v.data;
    if(t.equals("CodeUnit16"))return (char)(int)v.data;
    if(t.equals("Bytes")){List<?> xs=(List<?>)v.data;byte[] bytes=new byte[xs.size()];for(int i=0;i<bytes.length;i++)bytes[i]=(byte)(int)xs.get(i);return bytes;}
    if(t.equals("Utf16Text")){List<?> xs=(List<?>)v.data;char[] units=new char[xs.size()];for(int i=0;i<units.length;i++)units[i]=(char)(int)xs.get(i);return new String(units);}
    if(t.equals("Float32"))return ((Double)v.data).floatValue();
    if(t.equals("Text")){StringBuilder text=new StringBuilder();for(Object c:(List<?>)v.data)text.appendCodePoint((int)c);return text.toString();}
    return v.data;
  }
  public static Value fromNative(String t,Object value,int bits) {
    Value v;
    if(t.equals("Integer")&&!(value instanceof BigInteger || value instanceof Byte || value instanceof Short || value instanceof Integer || value instanceof Long || value instanceof Value))throw new IllegalArgumentException("invalid Integer representation");
    if(value instanceof Value scalar)v=scalar;
    else if(integerType(t))v=new Value(t,value instanceof BigInteger?value:BigInteger.valueOf(((Number)value).longValue()));
    else if(t.equals("Char")){int[] xs=((String)value).codePoints().toArray();if(xs.length!=1)throw new IllegalArgumentException("Char requires one Unicode scalar");v=character(t,xs[0]);}
    else if(t.equals("CodePoint"))v=character(t,(int)value);
    else if(t.equals("CodeUnit16"))v=character(t,(char)value);
    else if(t.equals("Bytes")){byte[] xs=(byte[])value;int[] units=new int[xs.length];for(int i=0;i<xs.length;i++)units[i]=Byte.toUnsignedInt(xs[i]);v=sequence(t,units);}
    else if(t.equals("Utf16Text"))v=sequence(t,((String)value).chars().toArray());
    else if(t.startsWith("Float"))v=new Value(t,((Number)value).doubleValue());
    else if(t.equals("Text"))v=sequence(t,((String)value).codePoints().toArray());
    else v=new Value(t,value);
    return validate(t,v,bits);
  }

  private static double exactFloat(Ratio r,boolean single) {
    if(r.n.signum()==0)return 0.0;
    boolean negative=r.n.signum()<0;BigInteger n=r.n.abs(),d=r.d;
    int p=single?24:53,bias=single?127:1023,emin=1-bias,emax=bias,e=n.bitLength()-d.bitLength();
    if(e>=0?n.compareTo(d.shiftLeft(e))<0:n.shiftLeft(-e).compareTo(d)<0)e--;
    if(e>emax)return negative?Double.NEGATIVE_INFINITY:Double.POSITIVE_INFINITY;
    int scale=Math.max(e,emin)-(p-1);BigInteger num=scale<0?n.shiftLeft(-scale):n,den=scale>0?d.shiftLeft(scale):d;
    BigInteger[] qr=num.divideAndRemainder(den);BigInteger q=qr[0];int cmp=qr[1].shiftLeft(1).compareTo(den);
    if(cmp>0||(cmp==0&&q.testBit(0)))q=q.add(BigInteger.ONE);
    e=Math.max(e,emin);if(q.equals(BigInteger.ONE.shiftLeft(p))){q=q.shiftRight(1);e++;}
    if(e>emax)return negative?Double.NEGATIVE_INFINITY:Double.POSITIVE_INFINITY;
    BigInteger hidden=BigInteger.ONE.shiftLeft(p-1);boolean subnormal=q.compareTo(hidden)<0;
    long exponent=subnormal?0:e+bias,mantissa=(subnormal?q:q.subtract(hidden)).longValue();
    long bits=((negative?1L:0L)<<(single?31:63))|(exponent<<(p-1))|mantissa;
    return single?(double)Float.intBitsToFloat((int)bits):Double.longBitsToDouble(bits);
  }

  public record Bound(String op, Value value) {}
  public record Domain(java.util.function.BiFunction<List<Value>,Integer,List<Value>> candidates, java.util.function.Predicate<List<Value>> accept) {}
  private static BigInteger floor(Ratio r) { BigInteger[] qr=r.n.divideAndRemainder(r.d);return qr[1].signum()<0?qr[0].subtract(BigInteger.ONE):qr[0]; }
  private static BigInteger ceil(Ratio r) { return floor(new Ratio(r.n.negate(),r.d)).negate(); }
  public static List<Value> domainCandidates(String t,int seed,int bits,Bound[] restrictions,Value[] hints) {
    var values=new ArrayList<Value>();for(Value hint:hints){try{values.add(convert(t,hint,bits));}catch(RuntimeException ignored){}}
    if(integerType(t)) {
      BigInteger lo=null,hi=null;
      if(t.equals("BigUInt"))lo=BigInteger.ZERO;
      else if(!List.of("Integer","BigInt").contains(t)){int w=t.endsWith("Size")||t.equals("UIntPtr")?bits:Integer.parseInt(t.replaceAll("\\D",""));boolean signed=t.startsWith("Int");lo=signed?BigInteger.ONE.shiftLeft(w-1).negate():BigInteger.ZERO;hi=BigInteger.ONE.shiftLeft(signed?w-1:w).subtract(BigInteger.ONE);}
      for(Bound b:restrictions){Ratio r=ratio(b.value);
        if(List.of(">",">=","==").contains(b.op)){BigInteger v=b.op.equals(">")?floor(r).add(BigInteger.ONE):ceil(r);lo=lo==null?v:lo.max(v);}
        if(List.of("<","<=","==").contains(b.op)){BigInteger v=b.op.equals("<")?ceil(r).subtract(BigInteger.ONE):floor(r);hi=hi==null?v:hi.min(v);}
      }
      if(lo!=null&&hi!=null&&lo.compareTo(hi)>0)return List.of();
      BigInteger lower=lo==null?(hi==null?BigInteger.ZERO:hi).min(BigInteger.ZERO).subtract(BigInteger.ONE.shiftLeft(256)):lo;
      BigInteger upper=hi==null?(lo==null?BigInteger.ZERO:lo).max(BigInteger.ZERO).add(BigInteger.ONE.shiftLeft(256)):hi;
      var ns=new ArrayList<BigInteger>(List.of(lower,upper,BigInteger.ZERO,BigInteger.ONE,BigInteger.ONE.negate(),lower.add(BigInteger.ONE),upper.subtract(BigInteger.ONE)));
      Random random=new Random(seed);BigInteger width=upper.subtract(lower).add(BigInteger.ONE);
      for(int j=0;j<8;j++)ns.add(lower.add(new BigInteger(width.bitLength(),random).mod(width)));
      for(BigInteger n:ns)values.add(new Value(t,n));
      values.removeIf(v->!integerType(v.type)||((BigInteger)v.data).compareTo(lower)<0||((BigInteger)v.data).compareTo(upper)>0);
      values.replaceAll(v->convert(t,v,bits));
    } else for(int j=0;j<8;j++)values.add(sample(t,seed+j*7919,bits));
    if(!values.isEmpty())Collections.rotate(values,-Math.floorMod(seed,values.size()));
    return values;
  }
  public static List<Value> generateTuple(Domain[] domains,int seed,int attempts,List<Value> prefix) {
    int[] used={0};while(used[0]<attempts){var result=searchDomain(domains,seed,attempts,used,new ArrayList<>(prefix));if(result!=null)return result;}
    throw new IllegalArgumentException("refinement-generation-exhausted after "+used[0]+" attempts; prefix="+prefix+"; seed="+seed);
  }
  private static List<Value> searchDomain(Domain[] domains,int seed,int attempts,int[] used,List<Value> values) {
    if(values.size()==domains.length)return values;if(used[0]>=attempts)return null;used[0]++;
    Domain domain=domains[values.size()];for(Value value:domain.candidates.apply(values,seed+used[0]*7919)){
      if(used[0]>=attempts)break;used[0]++;var next=new ArrayList<>(values);next.add(value);
      if(domain.accept.test(next)){var result=searchDomain(domains,seed,attempts,used,next);if(result!=null)return result;}
    }return null;
  }
  public static void requireContract(boolean condition,String context){if(!condition)throw new IllegalArgumentException(context);}
  public static Value contract(String context,boolean condition,Value result){requireContract(condition,context);return result;}
  public static void refinedCase(Domain[] domains,int seed,int attempts,int shrinks,java.util.function.Consumer<List<Value>> check,String context) {
    List<Value> values;try{values=generateTuple(domains,seed,attempts,List.of());}catch(RuntimeException error){throw new IllegalArgumentException(context+": "+error.getMessage(),error);}
    try{check.accept(values);}catch(RuntimeException|AssertionError original){var best=values;int budget=shrinks;
      for(int i=0;i<best.size();i++){
        Value value=best.get(i);var candidates=new ArrayList<Value>(domains[i].candidates.apply(best.subList(0,i),0));
        if(integerType(value.type)){BigInteger initial=(BigInteger)value.data;candidates.add(0,new Value(value.type,BigInteger.ZERO));candidates.add(1,new Value(value.type,BigInteger.valueOf(initial.signum())));
          for(BigInteger v=initial.divide(BigInteger.TWO);v.abs().compareTo(BigInteger.ONE)>0;v=v.divide(BigInteger.TWO))candidates.add(2,new Value(value.type,v));}
        for(Value candidate:candidates){if(budget--<=0)break;if(complexity(candidate).compareTo(complexity(best.get(i)))>=0)continue;
          var prefix=new ArrayList<>(best.subList(0,i));prefix.add(candidate);if(!domains[i].accept.test(prefix))continue;
          List<Value> trial;try{trial=generateTuple(domains,seed,Math.min(attempts,100),prefix);}catch(IllegalArgumentException error){if(error.getMessage().startsWith("refinement-generation-exhausted"))continue;throw error;}
          try{check.accept(trial);}catch(RuntimeException|AssertionError ignored){best=trial;}
        }
      }
      throw new AssertionError(context+": "+original.getMessage()+"; refined counterexample="+best+"; seed="+seed,original);
    }
  }

  private static BigInteger complexity(Value value){
    if(integerType(value.type))return ((BigInteger)value.data).abs();
    if(value.data instanceof Presence p)return p.present?complexity(p.value).add(BigInteger.ONE):BigInteger.ZERO;
    if(value.data instanceof List<?> xs)return BigInteger.valueOf(xs.size());
    if(value.data instanceof Boolean b)return b?BigInteger.ONE:BigInteger.ZERO;
    if(value.data instanceof Double d)return BigInteger.valueOf(Double.doubleToRawLongBits(Math.abs(d)));
    if(value.data instanceof Complex c)return complexity(new Value("Float64",c.real)).add(complexity(new Value("Float64",c.imaginary)));
    if(exactType(value.type)){Ratio r=ratio(value);return r.n.abs().add(r.d).subtract(BigInteger.ONE);}
    if(value.data instanceof Integer c)return BigInteger.valueOf(c);
    return value.data==null?BigInteger.ZERO:BigInteger.ONE;
  }
}
