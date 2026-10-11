// User-owned LawSpec adapter.
module Example.AtoiCodec

open System
open System.Globalization

let itoa (value: int) : string = value.ToString(CultureInfo.InvariantCulture)
let atoi (value: string) : int = Int32.Parse(value, NumberStyles.AllowLeadingSign, CultureInfo.InvariantCulture)
