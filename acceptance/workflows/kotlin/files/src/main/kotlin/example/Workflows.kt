// User-owned LawSpec adapter.
package example

import lawspec.data.Account
import lawspec.data.Order
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

    // Each check records when it fails, so approvalErrors can tell completion
    // order from declaration order.
    val finished = java.util.Collections.synchronizedList(mutableListOf<String>())

    // Order -1's slow checks record when they ran, so approvedQuickly can tell whether they ran at the same time.
    // The list is never cleared, so tests running at once cannot erase each other's records.
    val spans = java.util.Collections.synchronizedList(mutableListOf<Pair<Long, Long>>())

    // Whether two slow checks that started at or after since overlapped in time.
    fun overlapped(since: Long): Boolean {
        val ran = synchronized(spans) { spans.filter { it.first >= since } }
        return ran.indices.any { i -> (i + 1 until ran.size).any { j -> ran[i].first < ran[j].second && ran[j].first < ran[i].second } }
    }

    private suspend fun check(value0: Order, milliseconds: Long, problem: String): LawSpecRuntime.Either<String, Order> {
        if (value0.number == -1L) {
            val start = System.nanoTime()
            kotlinx.coroutines.delay(milliseconds)
            spans.add(Pair(start, System.nanoTime()))
        }
        if (value0.number >= 0) return LawSpecRuntime.Right(value0)
        finished.add(problem)
        return LawSpecRuntime.Left(problem)
    }

    // Order -1's stock check takes 400ms; a negative order has no stock.
    suspend fun checkStock(value0: Order): LawSpecRuntime.Either<String, Order> = check(value0, 400, "no stock")

    // Order -1's credit check takes 250ms; a negative order has no credit.
    suspend fun checkCredit(value0: Order): LawSpecRuntime.Either<String, Order> = check(value0, 250, "no credit")
}
