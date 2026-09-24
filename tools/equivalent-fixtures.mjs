// Alternative implementations exercised by the native integration suite.
export const equivalentAdapters = {
  java: [
    "src/main/java/example/Alternatives.java",
    `package example;
public final class Alternatives {
  public static String render(int x) { return Integer.toString(x); }
  public static String referenceRender(int x) { return String.valueOf(x); }
  public static int clamp(int x) { return Math.max(0, x); }
  public static int referenceClamp(int x) { return x < 0 ? 0 : x; }
}
`,
    "String.valueOf(x)",
    '"broken"',
    "x < 0 ? 0 : x",
    "-1",
  ],
  python: [
    "src/example/alternatives.py",
    `def render(x: int) -> str:
    return str(x)
def referenceRender(x: int) -> str:
    return f"{x:d}"
def clamp(x: int) -> int:
    return max(0, x)
def referenceClamp(x: int) -> int:
    return 0 if x < 0 else x
`,
    'f"{x:d}"',
    '"broken"',
    "0 if x < 0 else x",
    "-1",
  ],
  javascript: [
    "src/example/alternatives.mjs",
    `export const render = x => String(x);
export const referenceRender = x => x.toString(10);
export const clamp = x => Math.max(0, x);
export const referenceClamp = x => x < 0 ? 0 : x;
`,
    "x.toString(10)",
    '"broken"',
    "x < 0 ? 0 : x",
    "-1",
  ],
  typescript: [
    "src/example/alternatives.ts",
    `export const render = (x: number): string => String(x);
export const referenceRender = (x: number): string => x.toString(10);
export const clamp = (x: number): number => Math.max(0, x);
export const referenceClamp = (x: number): number => x < 0 ? 0 : x;
`,
    "x.toString(10)",
    '"broken"',
    "x < 0 ? 0 : x",
    "-1",
  ],
  go: [
    "example/alternatives/adapter.go",
    `package alternatives
import "strconv"
import "fmt"
func Render(x int32) string { return strconv.FormatInt(int64(x), 10) }
func ReferenceRender(x int32) string { return fmt.Sprintf("%d", x) }
func Clamp(x int32) int32 { return max(0, x) }
func ReferenceClamp(x int32) int32 { if x < 0 { return 0 }; return x }
`,
    'fmt.Sprintf("%d", x)',
    'fmt.Sprintf("broken%d", x)',
    "if x < 0 { return 0 }; return x",
    "return -1",
  ],
  haskell: [
    "src/Example/Alternatives.hs",
    `module Example.Alternatives where
import Data.Int (Int32)
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Lazy as TL
import qualified Data.Text.Lazy.Builder as B
import qualified Data.Text.Lazy.Builder.Int as B
render :: Int32 -> Text
render = T.pack . show
referenceRender :: Int32 -> Text
referenceRender = TL.toStrict . B.toLazyText . B.decimal
clamp :: Int32 -> Int32
clamp = max 0
referenceClamp :: Int32 -> Int32
referenceClamp x = if x < 0 then 0 else x
`,
    "TL.toStrict . B.toLazyText . B.decimal",
    'const (T.pack "broken")',
    "if x < 0 then 0 else x",
    "-1",
  ],
  kotlin: [
    "src/main/kotlin/example/Alternatives.kt",
    `package example
object Alternatives {
fun render(x: Int): String = x.toString()
fun referenceRender(x: Int): String = java.lang.Integer.toString(x)
fun clamp(x: Int): Int = maxOf(0, x)
fun referenceClamp(x: Int): Int = if (x < 0) 0 else x
}
`,
    "java.lang.Integer.toString(x)",
    '"broken"',
    "if (x < 0) 0 else x",
    "-1",
  ],
};
