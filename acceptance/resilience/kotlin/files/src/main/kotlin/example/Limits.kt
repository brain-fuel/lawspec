// User-owned LawSpec adapter.
package example

import lawspec.runtime.LawSpecRuntime

object Limits {
    fun admitTicket(value0: lawspec.data.Ticket): LawSpecRuntime.Either<String, lawspec.data.Ticket> = LawSpecRuntime.Right(value0)
}
