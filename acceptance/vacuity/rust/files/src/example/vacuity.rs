// Scaffolded by LawSpec from vacuity.lawspec. User-owned; never overwritten.

// shout — vacuity.lawspec:26
// LawSpec type: Text -> Text
pub fn shout(name: String) -> String
{
    name.to_uppercase()
}

// abbreviate — vacuity.lawspec:27
// LawSpec type: example.vacuity::type::Stage -> Text
pub fn abbreviate(stage: crate::lawspec_data::Stage) -> String
{
    stage.token
}

// accepts — vacuity.lawspec:28
// LawSpec type: example.vacuity::type::Proposal -> Bool
// Accepts only codes such as OFFER-2026-AB: no random record has one.
pub fn accepts(offer: crate::lawspec_data::Proposal) -> bool
{
    let code: Vec<char> = offer.code.chars().collect();
    code.len() == 13
        && code[..6].iter().collect::<String>() == "OFFER-"
        && code[6..10].iter().all(|c| c.is_ascii_digit())
        && code[10] == '-'
        && code[11..].iter().all(|c| c.is_ascii_uppercase())
        && offer.amount > 0
}

// describe — vacuity.lawspec:29
// LawSpec type: example.vacuity::type::Proposal -> Text
pub fn describe(offer: crate::lawspec_data::Proposal) -> String
{
    offer.code
}

// keep — vacuity.lawspec:30
// LawSpec type: Text -> Text
pub fn keep(key: String) -> String
{
    key
}
