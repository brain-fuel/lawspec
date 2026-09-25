// Partial renderers deliberately throw outside the predicate's domain.
// A passing suite therefore verifies implication's short-circuit behavior.
export function predicateAdapters(target) {
  const ports = {
    rust: [
      'src/example/parse_port.rs',
      `#![allow(non_snake_case)]
pub fn validPort(x:i32)->bool {x>=1 && x<=65535}
pub fn render(x:i32)->String {assert!(validPort(x),"invalid port"); x.to_string()}
pub fn parse(x:String)->i32 {x.parse().unwrap()}
`,
      'x>=1 && x<=65535', 'x.parse().unwrap()', '0',
    ],
    java: [
      "src/main/java/example/ParsePort.java",
      `package example;
public final class ParsePort {
 public static boolean validPort(int x) { return x >= 1 && x <= 65535; }
 public static String render(int x) { if (!validPort(x)) throw new IllegalArgumentException("invalid port"); return Integer.toString(x); }
 public static int parse(String x) { return Integer.parseInt(x); }
}`,
      "x >= 1 && x <= 65535",
      "Integer.parseInt(x)",
      "0",
    ],
    python: [
      "src/example/parse_port.py",
      `def validPort(x: int) -> bool:
    return x >= 1 and x <= 65535
def render(x: int) -> str:
    if not validPort(x):
        raise ValueError("invalid port")
    return str(x)
def parse(x: str) -> int:
    return int(x)
`,
      "x >= 1 and x <= 65535",
      "int(x)",
      "0",
    ],
    javascript: [
      "src/example/parse_port.mjs",
      `export const validPort = x => x >= 1 && x <= 65535;
export function render(x) { if (!validPort(x)) throw new Error("invalid port"); return String(x); }
export const parse = x => Number(x);
`,
      "x >= 1 && x <= 65535",
      "Number(x)",
      "0",
    ],
    typescript: [
      "src/example/parse_port.ts",
      `export const validPort = (x: number): boolean => x >= 1 && x <= 65535;
export function render(x: number): string { if (!validPort(x)) throw new Error("invalid port"); return String(x); }
export const parse = (x: string): number => Number(x);
`,
      "x >= 1 && x <= 65535",
      "Number(x)",
      "0",
    ],
    go: [
      "example/parse_port/adapter.go",
      `package parse_port
import "strconv"
func ValidPort(x int32) bool { return x >= 1 && x <= 65535 }
func Render(x int32) string { if !ValidPort(x) { panic("invalid port") }; return strconv.FormatInt(int64(x), 10) }
func Parse(x string) int32 { n, err := strconv.ParseInt(x, 10, 32); if err != nil { panic(err) }; return int32(n) }
`,
      "x >= 1 && x <= 65535",
      "return int32(n)",
      "return int32(n) - int32(n)",
    ],
    haskell: [
      "src/Example/ParsePort.hs",
      `module Example.ParsePort where
import Data.Int (Int32)
import Data.Text (Text)
import qualified Data.Text as T
validPort :: Int32 -> Bool
validPort x = x >= 1 && x <= 65535
render :: Int32 -> Text
render x = if validPort x then T.pack (show x) else error "invalid port"
parse :: Text -> Int32
parse = read . T.unpack
`,
      "x >= 1 && x <= 65535",
      "read . T.unpack",
      "const 0",
    ],
    kotlin: [
      "src/main/kotlin/example/ParsePort.kt",
      `package example
object ParsePort {
fun validPort(x: Int): Boolean = x >= 1 && x <= 65535
fun render(x: Int): String { require(validPort(x)); return x.toString() }
fun parse(x: String): Int = x.toInt()
}
`,
      "x >= 1 && x <= 65535",
      "x.toInt()",
      "0",
    ],
  };
  const flags = {
    rust: ['src/example/boolean_flags.rs', '#![allow(non_snake_case)]\npub fn flipFlag(x:bool)->bool {!x}\n', '!x', 'x'],
    java: [
      "src/main/java/example/BooleanFlags.java",
      "package example; public class BooleanFlags { public static boolean flipFlag(boolean x) { return !x; } }",
      "!x",
      "x",
    ],
    python: [
      "src/example/boolean_flags.py",
      "def flipFlag(x: bool) -> bool:\n    return not x\n",
      "not x",
      "x",
    ],
    javascript: [
      "src/example/boolean_flags.mjs",
      "export const flipFlag = x => !x;\n",
      "!x",
      "x",
    ],
    typescript: [
      "src/example/boolean_flags.ts",
      "export const flipFlag = (x: boolean): boolean => !x;\n",
      "!x",
      "x",
    ],
    go: [
      "example/boolean_flags/adapter.go",
      "package boolean_flags\nfunc FlipFlag(x bool) bool { return !x }\n",
      "!x",
      "x",
    ],
    haskell: [
      "src/Example/BooleanFlags.hs",
      "module Example.BooleanFlags where\nflipFlag :: Bool -> Bool\nflipFlag = not\n",
      "= not",
      "= id",
    ],
    kotlin: [
      "src/main/kotlin/example/BooleanFlags.kt",
      "package example\nobject BooleanFlags {\nfun flipFlag(x: Boolean): Boolean = !x\n}\n",
      "!x",
      "x",
    ],
  };
  const [file, good, predicate, parse, brokenParse] = ports[target];
  const bool = (b) =>
    target === "python" || target === "haskell"
      ? b
        ? "True"
        : "False"
      : String(b);
  return [
    [
      file,
      good,
      [
        good.replace(predicate, bool(false)),
        good.replace(predicate, bool(true)),
        good.replace(parse, brokenParse),
      ],
    ],
    [
      flags[target][0],
      flags[target][1],
      [flags[target][1].replace(flags[target][2], flags[target][3])],
    ],
  ];
}
