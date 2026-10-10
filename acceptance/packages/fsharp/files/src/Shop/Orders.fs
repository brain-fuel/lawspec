// User-owned LawSpec adapter. ref:DEC-acceptance-with-mutants
module Shop.Orders

open LawSpec.Data

let settlement (currency: ShopOrdersCurrency) : ShopDomainCurrency =
    match currency with
    | ShopOrdersCurrency.Usd -> ShopDomainCurrency.Usd
    | ShopOrdersCurrency.Gbp -> ShopDomainCurrency.Eur

let lineTotal (line: Line) : Money =
    let count = int64 line.Quantity.Value
    { Currency = line.Price.Currency; Cents = min (line.Price.Cents * count) 100000000L }

let cheaper (a: int64) (b: int64) : int64 = min a b

let roundDown (cents: int64) : int64 = cents - cents % 100L

// Version 2 of shop.tax: no tax on nothing, the high band from 100.00.
let classify (cents: int64) : ShopTaxV2x0x0RatesBand =
    if cents <= 0L then ShopTaxV2x0x0RatesBand.Zero
    elif cents < 10000L then ShopTaxV2x0x0RatesBand.Low
    else ShopTaxV2x0x0RatesBand.High
