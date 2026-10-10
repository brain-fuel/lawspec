// User-owned LawSpec adapter: async adapters return tasks.
// ref:DEC-acceptance-with-mutants
module Example.Orders

open System.Threading.Tasks

let private priceOf (sku: string) : int =
    if sku = "free" then 0 else Seq.length (sku.EnumerateRunes()) % 100

let price (sku: string) : Task<int> = task { return priceOf sku }

let stock (sku: string) : Task<int> = task { return Seq.length (sku.EnumerateRunes()) }

let quote (sku: string) : int = priceOf sku
