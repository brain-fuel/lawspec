// User-owned LawSpec adapter.
module Example.Vacuity

open System.Text.RegularExpressions

/// (Text -> Text)
let shout (name: string) : string = name.ToUpperInvariant()

/// (example.vacuity::type::Stage -> Text)
let abbreviate (stage: LawSpec.Data.Stage) : string = stage.Token

/// (example.vacuity::type::Proposal -> Bool)
/// Accepts only codes such as OFFER-2026-AB: no random record has one.
let accepts (offer: LawSpec.Data.Proposal) : bool =
    Regex.IsMatch(offer.Code, "^OFFER-[0-9]{4}-[A-Z]{2}$") && offer.Amount > 0

/// (example.vacuity::type::Proposal -> Text)
let describe (offer: LawSpec.Data.Proposal) : string = offer.Code

/// (Text -> Text)
let keep (key: string) : string = key
