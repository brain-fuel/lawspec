// User-owned LawSpec adapters for the matchers example.
// ref:DEC-acceptance-with-mutants
module Example.Matchers

open System.Text.RegularExpressions
open LawSpec.Data

let private words = Regex("[a-z0-9]+")

let sortItems (items: int list) : int list = List.sort items

let uniqueTags (tags: string list) : string list = List.distinct tags

let average (a: int) (b: int) : float = (float a + float b) / 2.0

let slug (text: string) : string =
    words.Matches(text.ToLowerInvariant()) |> Seq.map (fun m -> m.Value) |> String.concat "-"

let ship (id: int) : Order = Shipped(id, "post")
