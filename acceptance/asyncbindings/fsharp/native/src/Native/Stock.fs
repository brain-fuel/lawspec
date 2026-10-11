/// Application code the warehouse adapters are bound to: some of it
/// asynchronous, as a real service client would be.
module Warehouse.Stock

open System.Threading.Tasks

let private price (sku: string) : int =
    if sku = "free" then 0 else (sku.EnumerateRunes() |> Seq.length) % 100

let priceOf (sku: string) : Task<int> = Task.Run<int>(fun () -> price sku)

let quoteOf (sku: string) : int = price sku
