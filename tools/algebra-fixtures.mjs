// Int32 arithmetic is explicitly modulo 2^32, including on dynamic-language targets.
export function algebraAdapters(target) {
  const algebra = {
    java: [
      "src/main/java/example/Algebra.java",
      `package example;
public class Algebra {
 public static int add(int x,int y){return x+y;}
 public static int multiply(int x,int y){return x*y;}
 public static int negateValue(int x){return -x;}
 public static int maximumValue(int x,int y){return Math.max(x,y);}
 public static int subtractValue(int x,int y){return x-y;}
 public static int divideLeft(int x,int y){return x-y;}
 public static int divideRight(int x,int y){return x+y;}
}`,
      "return x*y;",
      "return x+y;",
      "divideRight(int x,int y){return x+y;}",
      "divideRight(int x,int y){return x-y;}",
    ],
    python: [
      "src/example/algebra.py",
      `def wrap(x): return (x + 2**31) % 2**32 - 2**31
def add(x: int,y: int) -> int: return wrap(x+y)
def multiply(x: int,y: int) -> int: return wrap(x*y)
def negateValue(x: int) -> int: return wrap(-x)
def maximumValue(x: int,y: int) -> int: return max(x,y)
def subtractValue(x: int,y: int) -> int: return wrap(x-y)
def divideLeft(x: int,y: int) -> int: return wrap(x-y)
def divideRight(x: int,y: int) -> int: return wrap(x+y)
`,
      "return wrap(x*y)",
      "return wrap(x+y)",
      "def divideRight(x: int,y: int) -> int: return wrap(x+y)",
      "def divideRight(x: int,y: int) -> int: return wrap(x-y)",
    ],
    go: [
      "example/algebra/adapter.go",
      `package algebra
func Add(x,y int32) int32 {return x+y}
func Multiply(x,y int32) int32 {return x*y}
func NegateValue(x int32) int32 {return -x}
func MaximumValue(x,y int32) int32 {return max(x,y)}
func SubtractValue(x,y int32) int32 {return x-y}
func DivideLeft(x,y int32) int32 {return x-y}
func DivideRight(x,y int32) int32 {return x+y}
`,
      "return x*y",
      "return x+y",
      "func DivideRight(x,y int32) int32 {return x+y}",
      "func DivideRight(x,y int32) int32 {return x-y}",
    ],
    haskell: [
      "src/Example/Algebra.hs",
      `module Example.Algebra where
import Data.Int (Int32)
add, multiply, maximumValue, subtractValue, divideLeft, divideRight :: Int32 -> Int32 -> Int32
add x y = x+y
multiply x y = x*y
maximumValue = max
subtractValue x y = x-y
divideLeft x y = x-y
divideRight x y = x+y
negateValue :: Int32 -> Int32
negateValue x = -x
`,
      "multiply x y = x*y",
      "multiply x y = x+y",
      "divideRight x y = x+y",
      "divideRight x y = x-y",
    ],
    kotlin: [
      "src/main/kotlin/example/Algebra.kt",
      `package example
object Algebra {
 fun add(x: Int,y: Int): Int = x+y
 fun multiply(x: Int,y: Int): Int = x*y
 fun negateValue(x: Int): Int = -x
 fun maximumValue(x: Int,y: Int): Int = maxOf(x,y)
 fun subtractValue(x: Int,y: Int): Int = x-y
 fun divideLeft(x: Int,y: Int): Int = x-y
 fun divideRight(x: Int,y: Int): Int = x+y
}
`,
      "fun multiply(x: Int,y: Int): Int = x*y",
      "fun multiply(x: Int,y: Int): Int = x+y",
      "fun divideRight(x: Int,y: Int): Int = x+y",
      "fun divideRight(x: Int,y: Int): Int = x-y",
    ],
  };
  const typed = target === "typescript";
  if (target === "javascript" || typed) {
    const t = typed ? ": number" : "";
    algebra[target] = [
      `src/example/algebra.${typed ? "ts" : "mjs"}`,
      `export const add = (x${t},y${t})${t} => (x+y)|0;
export const multiply = (x${t},y${t})${t} => Math.imul(x,y);
export const negateValue = (x${t})${t} => (-x)|0;
export const maximumValue = (x${t},y${t})${t} => Math.max(x,y);
export const subtractValue = (x${t},y${t})${t} => (x-y)|0;
export const divideLeft = (x${t},y${t})${t} => (x-y)|0;
export const divideRight = (x${t},y${t})${t} => (x+y)|0;
`,
      "Math.imul(x,y)",
      "(x+y)|0",
      `export const divideRight = (x${t},y${t})${t} => (x+y)|0;`,
      `export const divideRight = (x${t},y${t})${t} => (x-y)|0;`,
    ];
  }
  const curry = {
    java: [
      "src/main/java/example/Currying.java",
      `package example;
public class Currying {
 public static int sumFour(int a,int b,int c,int d){return a+b+c+d;}
 public static String format(String prefix,boolean enabled,int port,String suffix){return prefix+(enabled?Integer.toString(port):"")+suffix;}
 public static String referenceFormat(String prefix,boolean enabled,int port,String suffix){return String.join("",prefix,enabled?String.valueOf(port):"",suffix);}
 public static String trim(String x){return x.strip();}
}`,
      "return a+b+c+d;",
      "return a+b+c-d;",
    ],
    python: [
      "src/example/currying.py",
      `def sumFour(a: int,b: int,c: int,d: int) -> int: return (a+b+c+d+2**31)%2**32-2**31
def format(prefix: str,enabled: bool,port: int,suffix: str) -> str: return prefix+(str(port) if enabled else "")+suffix
def referenceFormat(prefix: str,enabled: bool,port: int,suffix: str) -> str: return "".join([prefix,str(port) if enabled else "",suffix])
def trim(x: str) -> str: return x.strip()
`,
      "a+b+c+d+2**31",
      "a+b+c-d+2**31",
    ],
    go: [
      "example/currying/adapter.go",
      `package currying
import "strconv"
import "strings"
func SumFour(a,b,c,d int32) int32 {return a+b+c+d}
func Format(prefix string,enabled bool,port int32,suffix string) string {n:=""; if enabled {n=strconv.FormatInt(int64(port),10)}; return prefix+n+suffix}
func ReferenceFormat(prefix string,enabled bool,port int32,suffix string) string {parts:=[]string{prefix}; if enabled {parts=append(parts,strconv.FormatInt(int64(port),10))}; return strings.Join(append(parts,suffix),"")}
func Trim(x string) string {return strings.TrimSpace(x)}
`,
      "return a+b+c+d",
      "return a+b+c-d",
    ],
    haskell: [
      "src/Example/Currying.hs",
      `module Example.Currying where
import Data.Int (Int32)
import Data.Text (Text)
import qualified Data.Text as T
sumFour :: Int32 -> Int32 -> Int32 -> Int32 -> Int32
sumFour a b c d = a+b+c+d
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
 fun sumFour(a: Int,b: Int,c: Int,d: Int): Int = a+b+c+d
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
    const n = typed ? ": number" : "",
      s = typed ? ": string" : "",
      b = typed ? ": boolean" : "";
    curry[target] = [
      `src/example/currying.${typed ? "ts" : "mjs"}`,
      `export const sumFour = (a${n},b${n},c${n},d${n})${n} => (a+b+c+d)|0;
export const format = (prefix${s},enabled${b},port${n},suffix${s})${s} => prefix+(enabled?String(port):"")+suffix;
export const referenceFormat = (prefix${s},enabled${b},port${n},suffix${s})${s} => [prefix,enabled?port.toString():"",suffix].join("");
export const trim = (x${s})${s} => x.trim();
`,
      "a+b+c+d",
      "a+b+c-d",
    ];
  }
  return [algebra[target], curry[target]];
}
