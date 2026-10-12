package example
@groovy.transform.CompileStatic
final class Alternatives {
  static String render(int x) { return Integer.toString(x); }
  static String referenceRender(int x) { return String.valueOf(x); }
  static int clamp(int x) { return Math.max(0, x); }
  static int referenceClamp(int x) { return x < 0 ? 0 : x; }
}
