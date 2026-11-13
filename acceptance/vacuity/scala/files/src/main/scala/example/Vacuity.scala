// User-owned LawSpec adapter.
package example

import lawspec.data.Offer
import lawspec.data.Stage

object Vacuity {
  def shout(value0: java.lang.String): java.lang.String = value0.toUpperCase(java.util.Locale.ROOT)

  def abbreviate(value0: Stage): java.lang.String = value0.token

  // Accepts only codes such as OFFER-2026-AB: no random record has one.
  def accepts(value0: Offer): scala.Boolean =
    value0.code.matches("OFFER-[0-9]{4}-[A-Z]{2}") && value0.amount > 0

  def describe(value0: Offer): java.lang.String = value0.code

  def keep(value0: java.lang.String): java.lang.String = value0
}
