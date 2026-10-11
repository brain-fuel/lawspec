/// Application types, independent of generated LawSpec domain declarations.
module Domain.PaymentsDomain

open LawSpec

type CurrencyCode =
    | Dollars
    | Euros
    | Pounds

type Price = { major: ExactDecimal; unit: CurrencyCode }

type PaymentStatus =
    | Settled of price: Price
    | Rejected of explanation: string

let private fee: ExactDecimal = { Coefficient = 2I; Exponent = -1 }

let apply_fee (price: Price) : Price = { price with major = price.major + fee }

let restore (payment: PaymentStatus) : PaymentStatus = payment

let store (payments: PaymentStatus option list) : PaymentStatus option list = payments
