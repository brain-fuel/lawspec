// User-owned LawSpec adapter.
package example

import lawspec.runtime.LawSpecRuntime

object Limits {
    fun admitTicket(value0: lawspec.data.Ticket): LawSpecRuntime.Either<String, lawspec.data.Ticket> = LawSpecRuntime.Right(value0)

    fun reserveSeat(value0: lawspec.data.Ticket): LawSpecRuntime.Either<String, lawspec.data.Ticket> = LawSpecRuntime.Right(value0)

    fun chargeCard(value0: lawspec.data.Ticket): LawSpecRuntime.Either<String, lawspec.data.Ticket> =
        if (value0.number < 0) LawSpecRuntime.Left("declined") else LawSpecRuntime.Right(value0)

    fun releaseSeat(value0: lawspec.data.Ticket): Boolean = true
}
