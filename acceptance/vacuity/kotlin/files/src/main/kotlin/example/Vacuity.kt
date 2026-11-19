// User-owned LawSpec adapter.
package example

object Vacuity {
    private val offerCode = Regex("OFFER-[0-9]{4}-[A-Z]{2}")

    // shout :: (Text -> Text) — vacuity.lawspec:26
    fun shout(name: kotlin.String): kotlin.String = name.uppercase(java.util.Locale.ROOT)

    // abbreviate :: (example.vacuity::type::Stage -> Text) — vacuity.lawspec:27
    fun abbreviate(stage: lawspec.data.Stage): kotlin.String = stage.token

    // accepts :: (example.vacuity::type::Proposal -> Bool) — vacuity.lawspec:28
    // Accepts only codes such as OFFER-2026-AB: no random record has one.
    fun accepts(offer: lawspec.data.Proposal): kotlin.Boolean = offerCode.matches(offer.code) && offer.amount > 0

    // describe :: (example.vacuity::type::Proposal -> Text) — vacuity.lawspec:29
    fun describe(offer: lawspec.data.Proposal): kotlin.String = offer.code

    // keep :: (Text -> Text) — vacuity.lawspec:30
    fun keep(key: kotlin.String): kotlin.String = key
}
