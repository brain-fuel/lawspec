// User-owned LawSpec adapter. ref:DEC-acceptance-with-mutants
module Shop.Domain

open LawSpec.Data

// One-to-one rates keep the example exact.
let convert (currency: ShopDomainCurrency) (money: Money) : Money = { money with Currency = currency }
