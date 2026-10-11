// User-owned LawSpec adapter.
module Example.Mixed.Inputs

let normalize (x: string) : string = x.Replace(" ", "-")
let identity (x: int) : int = x
