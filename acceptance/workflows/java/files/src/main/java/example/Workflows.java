// User-owned LawSpec adapter.
package example;

import java.util.ArrayList;
import java.util.List;
import java.util.concurrent.CompletableFuture;
import java.util.concurrent.TimeUnit;
import lawspec.data.Account;
import lawspec.data.ApproveError;
import lawspec.data.Order;
import lawspec.data.Signup;
import lawspec.data.SignupError;
import lawspec.runtime.LawSpecRuntime;

public final class Workflows {
  public static boolean audit(Account value0) {
    return true;
  }

  public static LawSpecRuntime.Either<SignupError, Account> waitlist(SignupError value0) {
    if (value0 instanceof SignupError.Unavailable) {
      return new LawSpecRuntime.Right<>(new Account("waitlist", 18, 0));
    }
    return new LawSpecRuntime.Left<>(value0);
  }

  public static LawSpecRuntime.Either<SignupError, Signup> checkName(Signup value0) {
    if (value0.name().isEmpty()) return new LawSpecRuntime.Left<>(new SignupError.MissingName());
    return new LawSpecRuntime.Right<>(value0);
  }

  public static LawSpecRuntime.Either<String, Signup> checkAge(Signup value0) {
    if (value0.age() < 18) return new LawSpecRuntime.Left<>("too young");
    return new LawSpecRuntime.Right<>(value0);
  }

  public static LawSpecRuntime.Either<SignupError, Account> openAccount(Signup value0) {
    if (value0.name().equals("taken")) return new LawSpecRuntime.Left<>(new SignupError.Unavailable());
    return new LawSpecRuntime.Right<>(new Account(value0.name(), value0.age(), 1));
  }

  // Each check records when it fails, so approvalErrors can tell completion
  // order from declaration order.
  static final List<String> finished = java.util.Collections.synchronizedList(new ArrayList<>());

  private static CompletableFuture<LawSpecRuntime.Either<String, Order>> check(
      Order value0, long milliseconds, String problem) {
    var executor = value0.number() == -1
        ? CompletableFuture.delayedExecutor(milliseconds, TimeUnit.MILLISECONDS)
        : java.util.concurrent.ForkJoinPool.commonPool();
    return CompletableFuture.supplyAsync(() -> {
      if (value0.number() >= 0) return new LawSpecRuntime.Right<>(value0);
      finished.add(problem);
      return new LawSpecRuntime.Left<>(problem);
    }, executor);
  }

  /** Order -1's stock check takes 400ms; a negative order has no stock. */
  public static CompletableFuture<LawSpecRuntime.Either<String, Order>> checkStock(Order value0) {
    return check(value0, 400, "no stock");
  }

  /** Order -1's credit check takes 250ms; a negative order has no credit. */
  public static CompletableFuture<LawSpecRuntime.Either<String, Order>> checkCredit(Order value0) {
    return check(value0, 250, "no credit");
  }
}
