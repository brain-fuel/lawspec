// User-owned LawSpec adapter.
module Example.Alternatives

open System.Globalization

let render (x: int) : string = x.ToString(CultureInfo.InvariantCulture)
let referenceRender (x: int) : string = string x
let clamp (x: int) : int = max 0 x
let referenceClamp (x: int) : int = if x < 0 then 0 else x
