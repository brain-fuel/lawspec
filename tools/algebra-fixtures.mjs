// Algebra adapters preserve mathematical integers on every target.
export function algebraAdapters(target) {
  const algebra = {
    java: [
      'src/main/java/example/Algebra.java',
      `package example;
import java.math.BigInteger;
public class Algebra {
 public static Number add(BigInteger x,BigInteger y){return x.add(y);}
 public static Number multiply(BigInteger x,BigInteger y){return x.multiply(y);}
 public static Number negateValue(BigInteger x){return x.negate();}
 public static Number maximumValue(BigInteger x,BigInteger y){return x.max(y);}
 public static Number subtractValue(BigInteger x,BigInteger y){return x.subtract(y);}
 public static Number divideLeft(BigInteger x,BigInteger y){return x.subtract(y);}
 public static Number divideRight(BigInteger x,BigInteger y){return x.add(y);}
}`,
      'return x.multiply(y);', 'return x.add(y);',
      'divideRight(BigInteger x,BigInteger y){return x.add(y);}', 'divideRight(BigInteger x,BigInteger y){return x.subtract(y);}',
      'add(BigInteger x,BigInteger y){return x.add(y);}', 'add(BigInteger x,BigInteger y){return x.add(y).intValue();}',
    ],
    python: [
      'src/example/algebra.py',
      `def add(x: int,y: int) -> int: return x+y
def multiply(x: int,y: int) -> int: return x*y
def negateValue(x: int) -> int: return -x
def maximumValue(x: int,y: int) -> int: return max(x,y)
def subtractValue(x: int,y: int) -> int: return x-y
def divideLeft(x: int,y: int) -> int: return x-y
def divideRight(x: int,y: int) -> int: return x+y
`,
      'return x*y', 'return x+y',
      'def divideRight(x: int,y: int) -> int: return x+y', 'def divideRight(x: int,y: int) -> int: return x-y',
      'def add(x: int,y: int) -> int: return x+y', 'def add(x: int,y: int) -> int: return (x+y+2**31)%2**32-2**31',
    ],
    go: [
      'example/algebra/adapter.go',
      `package algebra
func Add(x,y *LawSpecBigInt) any {return new(LawSpecBigInt).Add(x,y)}
func Multiply(x,y *LawSpecBigInt) any {return new(LawSpecBigInt).Mul(x,y)}
func NegateValue(x *LawSpecBigInt) any {return new(LawSpecBigInt).Neg(x)}
func MaximumValue(x,y *LawSpecBigInt) any {if x.Cmp(y)>0 {return x}; return y}
func SubtractValue(x,y *LawSpecBigInt) any {return new(LawSpecBigInt).Sub(x,y)}
func DivideLeft(x,y *LawSpecBigInt) any {return new(LawSpecBigInt).Sub(x,y)}
func DivideRight(x,y *LawSpecBigInt) any {return new(LawSpecBigInt).Add(x,y)}
`,
      'return new(LawSpecBigInt).Mul(x,y)', 'return new(LawSpecBigInt).Add(x,y)',
      'func DivideRight(x,y *LawSpecBigInt) any {return new(LawSpecBigInt).Add(x,y)}', 'func DivideRight(x,y *LawSpecBigInt) any {return new(LawSpecBigInt).Sub(x,y)}',
      'func Add(x,y *LawSpecBigInt) any {return new(LawSpecBigInt).Add(x,y)}', 'func Add(x,y *LawSpecBigInt) any {return int32(new(LawSpecBigInt).Add(x,y).Int64())}',
    ],
    haskell: [
      'src/Example/Algebra.hs',
      `module Example.Algebra where
import Data.Int (Int32)
import LawSpecRuntime (IntegerValue,integerValue)
add, multiply, maximumValue, subtractValue, divideLeft, divideRight :: Integer -> Integer -> IntegerValue
add x y = integerValue (x+y)
multiply x y = integerValue (x*y)
maximumValue x y = integerValue (max x y)
subtractValue x y = integerValue (x-y)
divideLeft x y = integerValue (x-y)
divideRight x y = integerValue (x+y)
negateValue :: Integer -> IntegerValue
negateValue x = integerValue (-x)
`,
      'multiply x y = integerValue (x*y)', 'multiply x y = integerValue (x+y)',
      'divideRight x y = integerValue (x+y)', 'divideRight x y = integerValue (x-y)',
      'add x y = integerValue (x+y)', 'add x y = integerValue (fromInteger (x+y) :: Int32)',
    ],
    kotlin: [
      'src/main/kotlin/example/Algebra.kt',
      `package example
import java.math.BigInteger
object Algebra {
 fun add(x: BigInteger,y: BigInteger): Number = x+y
 fun multiply(x: BigInteger,y: BigInteger): Number = x*y
 fun negateValue(x: BigInteger): Number = -x
 fun maximumValue(x: BigInteger,y: BigInteger): Number = maxOf(x,y)
 fun subtractValue(x: BigInteger,y: BigInteger): Number = x-y
 fun divideLeft(x: BigInteger,y: BigInteger): Number = x-y
 fun divideRight(x: BigInteger,y: BigInteger): Number = x+y
}
`,
      'fun multiply(x: BigInteger,y: BigInteger): Number = x*y', 'fun multiply(x: BigInteger,y: BigInteger): Number = x+y',
      'fun divideRight(x: BigInteger,y: BigInteger): Number = x+y', 'fun divideRight(x: BigInteger,y: BigInteger): Number = x-y',
      'fun add(x: BigInteger,y: BigInteger): Number = x+y', 'fun add(x: BigInteger,y: BigInteger): Number = (x+y).toInt()',
    ],
    rust: [
      'src/example/algebra.rs',
      `#![allow(non_snake_case)]
use crate::lawspec_runtime::{BigInt,Integer};
pub fn add(x:BigInt,y:BigInt)->Integer {(x+y).into()}
pub fn multiply(x:BigInt,y:BigInt)->Integer {(x*y).into()}
pub fn negateValue(x:BigInt)->Integer {(-x).into()}
pub fn maximumValue(x:BigInt,y:BigInt)->Integer {x.max(y).into()}
pub fn subtractValue(x:BigInt,y:BigInt)->Integer {(x-y).into()}
pub fn divideLeft(x:BigInt,y:BigInt)->Integer {(x-y).into()}
pub fn divideRight(x:BigInt,y:BigInt)->Integer {(x+y).into()}
`,
      'pub fn multiply(x:BigInt,y:BigInt)->Integer {(x*y).into()}', 'pub fn multiply(x:BigInt,y:BigInt)->Integer {(x+y).into()}',
      'pub fn divideRight(x:BigInt,y:BigInt)->Integer {(x+y).into()}', 'pub fn divideRight(x:BigInt,y:BigInt)->Integer {(x-y).into()}',
      'pub fn add(x:BigInt,y:BigInt)->Integer {(x+y).into()}', 'pub fn add(x:BigInt,y:BigInt)->Integer {use num_traits::ToPrimitive; (((x+y)&BigInt::from(u32::MAX)).to_u32().unwrap() as i32).into()}',
    ],
  };
  const typed = target === 'typescript';
  if (target === 'javascript' || typed) {
    const t = typed ? ': bigint' : '';
    algebra[target] = [
      `src/example/algebra.${typed ? 'ts' : 'mjs'}`,
      `export const add = (x${t},y${t})${t} => x+y;
export const multiply = (x${t},y${t})${t} => x*y;
export const negateValue = (x${t})${t} => -x;
export const maximumValue = (x${t},y${t})${t} => x>y?x:y;
export const subtractValue = (x${t},y${t})${t} => x-y;
export const divideLeft = (x${t},y${t})${t} => x-y;
export const divideRight = (x${t},y${t})${t} => x+y;
`,
      '=> x*y;', '=> x+y;',
      `export const divideRight = (x${t},y${t})${t} => x+y;`, `export const divideRight = (x${t},y${t})${t} => x-y;`,
      `export const add = (x${t},y${t})${t} => x+y;`, `export const add = (x${t},y${t})${t} => BigInt.asIntN(32,x+y);`,
    ];
  }
  const curry = {
    java: [
      "src/main/java/example/Currying.java",
      `package example;
public class Currying {
 public static Number sumFour(java.math.BigInteger a,java.math.BigInteger b,java.math.BigInteger c,java.math.BigInteger d){return a.add(b).add(c).add(d);}
 public static String format(String prefix,boolean enabled,int port,String suffix){return prefix+(enabled?Integer.toString(port):"")+suffix;}
 public static String referenceFormat(String prefix,boolean enabled,int port,String suffix){return String.join("",prefix,enabled?String.valueOf(port):"",suffix);}
 public static String trim(String x){return x.strip();}
}`,
      "return a.add(b).add(c).add(d);",
      "return a.add(b).add(c).subtract(d);",
    ],
    python: [
      "src/example/currying.py",
      `def sumFour(a: int,b: int,c: int,d: int) -> int: return a+b+c+d
def format(prefix: str,enabled: bool,port: int,suffix: str) -> str: return prefix+(str(port) if enabled else "")+suffix
def referenceFormat(prefix: str,enabled: bool,port: int,suffix: str) -> str: return "".join([prefix,str(port) if enabled else "",suffix])
def trim(x: str) -> str: return x.strip()
`,
      "a+b+c+d",
      "a+b+c-d",
    ],
    go: [
      "example/currying/adapter.go",
      `package currying
import "strconv"
import "strings"
func SumFour(a,b,c,d *LawSpecBigInt) any {return new(LawSpecBigInt).Add(new(LawSpecBigInt).Add(new(LawSpecBigInt).Add(a,b),c),d)}
func Format(prefix string,enabled bool,port int32,suffix string) string {n:=""; if enabled {n=strconv.FormatInt(int64(port),10)}; return prefix+n+suffix}
func ReferenceFormat(prefix string,enabled bool,port int32,suffix string) string {parts:=[]string{prefix}; if enabled {parts=append(parts,strconv.FormatInt(int64(port),10))}; return strings.Join(append(parts,suffix),"")}
func Trim(x string) string {return strings.TrimSpace(x)}
`,
      "return new(LawSpecBigInt).Add(new(LawSpecBigInt).Add(new(LawSpecBigInt).Add(a,b),c),d)",
      "return new(LawSpecBigInt).Sub(new(LawSpecBigInt).Add(new(LawSpecBigInt).Add(a,b),c),d)",
    ],
    haskell: [
      "src/Example/Currying.hs",
      `module Example.Currying where
import LawSpecRuntime (IntegerValue,integerValue)
import Data.Int (Int32)
import Data.Text (Text)
import qualified Data.Text as T
sumFour :: Integer -> Integer -> Integer -> Integer -> IntegerValue
sumFour a b c d = integerValue (a+b+c+d)
format, referenceFormat :: Text -> Bool -> Int32 -> Text -> Text
format prefix enabled port suffix = prefix <> (if enabled then T.pack (show port) else T.empty) <> suffix
referenceFormat prefix enabled port suffix = T.concat [prefix, if enabled then T.pack (show port) else T.empty, suffix]
trim :: Text -> Text
trim = T.strip
`,
      "a+b+c+d",
      "a+b+c-d",
    ],
    kotlin: [
      "src/main/kotlin/example/Currying.kt",
      `package example
object Currying {
 fun sumFour(a: java.math.BigInteger,b: java.math.BigInteger,c: java.math.BigInteger,d: java.math.BigInteger): Number = a+b+c+d
 fun format(prefix: String,enabled: Boolean,port: Int,suffix: String): String = prefix+(if(enabled) port.toString() else "")+suffix
 fun referenceFormat(prefix: String,enabled: Boolean,port: Int,suffix: String): String = listOf(prefix,if(enabled) port.toString() else "",suffix).joinToString("")
 fun trim(x: String): String = x.trim()
}
`,
      "a+b+c+d",
      "a+b+c-d",
    ],
  };
  if (target === "javascript" || typed) {
    const i = typed ? ": bigint" : "",
      n = typed ? ": number" : "",
      s = typed ? ": string" : "",
      b = typed ? ": boolean" : "";
    curry[target] = [
      `src/example/currying.${typed ? "ts" : "mjs"}`,
      `export const sumFour = (a${i},b${i},c${i},d${i})${i} => a+b+c+d;
export const format = (prefix${s},enabled${b},port${n},suffix${s})${s} => prefix+(enabled?String(port):"")+suffix;
export const referenceFormat = (prefix${s},enabled${b},port${n},suffix${s})${s} => [prefix,enabled?port.toString():"",suffix].join("");
export const trim = (x${s})${s} => x.trim();
`,
      "a+b+c+d",
      "a+b+c-d",
    ];
  }
  curry.rust = [
    'src/example/currying.rs',
    `#![allow(non_snake_case)]
use crate::lawspec_runtime::{BigInt,Integer};
pub fn sumFour(a:BigInt,b:BigInt,c:BigInt,d:BigInt)->Integer {(a+b+c+d).into()}
pub fn format(prefix:String,enabled:bool,port:i32,suffix:String)->String {prefix+&if enabled {port.to_string()} else {String::new()}+&suffix}
pub fn referenceFormat(prefix:String,enabled:bool,port:i32,suffix:String)->String {[prefix,if enabled {port.to_string()} else {String::new()},suffix].concat()}
pub fn trim(x:String)->String {x.trim().to_owned()}
`,
    '(a+b+c+d).into()', '(a+b+c-d).into()',
  ];
  return [algebra[target], curry[target]];
}
