package example;
public final class Alternatives {
  public static String render(int x) { return Integer.toString(x); }
  public static String referenceRender(int x) { return String.valueOf(x); }
  public static int clamp(int x) { return Math.max(0, x); }
  public static int referenceClamp(int x) { return x < 0 ? 0 : x; }
}
