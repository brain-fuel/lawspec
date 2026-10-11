// User-owned LawSpec adapter.
module Example.ParsePort

open System
open System.Globalization

let validPort (x: int) : bool = x >= 1 && x <= 65535
let render (x: int) : string = if validPort x then string x else invalidArg "x" "invalid port"
let parse (x: string) : int = Int32.Parse(x, NumberStyles.AllowLeadingSign, CultureInfo.InvariantCulture)
