namespace Till

open LawSpec.Abilities.ExampleTill

/// The application's error for a declined card.
type CardDeclined() =
    inherit exn("declined")

/// The application's error for an amount it cannot take.
type BadAmount(message: string) =
    inherit exn(message)

/// A till that keeps what it takes: the production handler, in the application's types.
type NativeTill() =
    let mutable taken = 0L
    interface IDrawer with
        member _.Take(money: Cash) =
            taken <- taken + money.Cents
            { Cents = money.Cents }
        member _.Opening() = { Cents = 0L }

/// Payments: a bound adapter. It gets its till as the generated interface.
module Payments =
    let pay (till: IDrawer) (cents: int64) : Cash =
        if cents < 0L then raise (BadAmount "negative")
        if cents > 1000L then raise (CardDeclined())
        { Cents = (till.Take { Cents = cents }).Cents }
