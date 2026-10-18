package example;
import lawspec.data.Shown;
public final class Gadt {
  public static String describe(Shown value) { return value.witness(); }
}
