// User-owned LawSpec adapter.
package example;

import lawspec.data.Account;
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
}
