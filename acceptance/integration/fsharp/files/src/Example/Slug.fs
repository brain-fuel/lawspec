// User-owned LawSpec adapter.
module Example.Slug

let normalize (x: string) : string = x.Replace(" ", "-")
let referenceNormalize (x: string) : string = x.Replace(' ', '-')
