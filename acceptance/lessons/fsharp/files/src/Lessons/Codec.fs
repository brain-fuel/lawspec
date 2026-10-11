// User-owned LawSpec adapter.
module Lessons.Codec

open System.Globalization

let formatQuantity (value0: int) : string = value0.ToString(CultureInfo.InvariantCulture)

let parseQuantity (value0: string) : int = System.Int32.Parse(value0, CultureInfo.InvariantCulture)
