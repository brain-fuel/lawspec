// User-owned LawSpec adapter.
package example;

import lawspec.runtime.LawSpecRuntime;

public final class Limits {
  public static LawSpecRuntime.Either<String, lawspec.data.Ticket> admitTicket(lawspec.data.Ticket value0) {
    return new LawSpecRuntime.Right<>(value0);
  }

  public static LawSpecRuntime.Either<String, lawspec.data.Ticket> reserveSeat(lawspec.data.Ticket value0) {
    return new LawSpecRuntime.Right<>(value0);
  }

  public static LawSpecRuntime.Either<String, lawspec.data.Ticket> chargeCard(lawspec.data.Ticket value0) {
    if (value0.number() < 0) return new LawSpecRuntime.Left<>("declined");
    return new LawSpecRuntime.Right<>(value0);
  }

  public static boolean releaseSeat(lawspec.data.Ticket value0) {
    return true;
  }
}
