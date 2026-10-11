// User-owned LawSpec adapter.
module Example.CanonicalUrl

let canonicalize (x: string) : string = x.TrimEnd '/'
