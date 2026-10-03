// User-owned LawSpec adapter.
package example

import lawspec.data.Account
import lawspec.data.Signup
import lawspec.data.SignupError
import lawspec.runtime.LawSpecRuntime

object Workflows {
    fun audit(value0: Account): Boolean = true

    fun waitlist(value0: SignupError): LawSpecRuntime.Either<SignupError, Account> {
        if (value0 == SignupError.Unavailable) return LawSpecRuntime.Right(Account("waitlist", 18, 0))
        return LawSpecRuntime.Left(value0)
    }

    fun checkName(value0: Signup): LawSpecRuntime.Either<SignupError, Signup> {
        if (value0.name.isEmpty()) return LawSpecRuntime.Left(SignupError.MissingName)
        return LawSpecRuntime.Right(value0)
    }

    fun checkAge(value0: Signup): LawSpecRuntime.Either<String, Signup> {
        if (value0.age < 18) return LawSpecRuntime.Left("too young")
        return LawSpecRuntime.Right(value0)
    }

    fun openAccount(value0: Signup): LawSpecRuntime.Either<SignupError, Account> {
        if (value0.name == "taken") return LawSpecRuntime.Left(SignupError.Unavailable)
        return LawSpecRuntime.Right(Account(value0.name, value0.age, 1))
    }
}
