// User-owned LawSpec adapter.
package example

@groovy.transform.CompileStatic
final class Vacuity
{
  // shout :: (Text -> Text) — vacuity.lawspec:26
  static String shout(String name)
  {
    name.toUpperCase(Locale.ROOT)
  }

  // abbreviate :: (example.vacuity::type::Stage -> Text) — vacuity.lawspec:27
  static String abbreviate(lawspec.data.Stage stage)
  {
    stage.token()
  }

  // accepts :: (example.vacuity::type::Proposal -> Bool) — vacuity.lawspec:28
  // Accepts only codes such as OFFER-2026-AB: no random record has one.
  static boolean accepts(lawspec.data.Proposal offer)
  {
    offer.code().matches('OFFER-[0-9]{4}-[A-Z]{2}') && offer.amount() > 0
  }

  // describe :: (example.vacuity::type::Proposal -> Text) — vacuity.lawspec:29
  static String describe(lawspec.data.Proposal offer)
  {
    offer.code()
  }

  // keep :: (Text -> Text) — vacuity.lawspec:30
  static String keep(String key)
  {
    key
  }
}
