// User-owned LawSpec adapter.
package example;

public final class Vacuity {
  public static String shout(String value0) {
    return value0.toUpperCase(java.util.Locale.ROOT);
  }

  public static String abbreviate(lawspec.data.Stage value0) {
    return value0.token();
  }

  // Accepts only codes such as OFFER-2026-AB: no random record has one.
  public static boolean accepts(lawspec.data.Offer value0) {
    return value0.code().matches("OFFER-[0-9]{4}-[A-Z]{2}") && value0.amount() > 0;
  }

  public static String describe(lawspec.data.Offer value0) {
    return value0.code();
  }

  public static String keep(String value0) {
    return value0;
  }
}
