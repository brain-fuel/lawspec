// User-owned LawSpec adapter.
package example;

import lawspec.runtime.LawSpecRuntime;

public final class Limits {
  public static LawSpecRuntime.Either<String, lawspec.data.Ticket> admitTicket(lawspec.data.Ticket value0) {
    return new LawSpecRuntime.Right<>(value0);
  }
}
