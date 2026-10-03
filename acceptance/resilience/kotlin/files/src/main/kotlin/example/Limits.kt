// User-owned LawSpec adapter.
package example

import lawspec.runtime.LawSpecRuntime

object Limits {
    fun admitTicket(value0: lawspec.data.Ticket): LawSpecRuntime.Either<String, lawspec.data.Ticket> = LawSpecRuntime.Right(value0)

    fun reserveSeat(value0: lawspec.data.Ticket): LawSpecRuntime.Either<String, lawspec.data.Ticket> = LawSpecRuntime.Right(value0)

    fun chargeCard(value0: lawspec.data.Ticket): LawSpecRuntime.Either<String, lawspec.data.Ticket> =
        if (value0.number < 0) LawSpecRuntime.Left("declined") else LawSpecRuntime.Right(value0)

    fun releaseSeat(value0: lawspec.data.Ticket): Boolean = true

    private val quotes = java.util.concurrent.atomic.AtomicLong()

    fun resetQuotes() = quotes.set(0)

    // Ticket -2's first quote (and every other one after) stalls.
    suspend fun hedgeQuote(value0: lawspec.data.Ticket): LawSpecRuntime.Either<String, lawspec.data.Ticket> {
        if (value0.number == -2L && quotes.incrementAndGet() % 2 == 1L) kotlinx.coroutines.delay(600)
        return LawSpecRuntime.Right(value0)
    }

    // Ticket -1's quote takes 600ms.
    suspend fun fetchQuote(value0: lawspec.data.Ticket): LawSpecRuntime.Either<String, lawspec.data.Ticket> {
        if (value0.number == -1L) kotlinx.coroutines.delay(600)
        return LawSpecRuntime.Right(value0)
    }
}
