// User-owned LawSpec adapter. ref:DEC-acceptance-with-mutants
module Example.Currying

let sumFour (a: bigint) (b: bigint) (c: bigint) (d: bigint) : bigint = a + b + c + d

let format (prefix: string) (enabled: bool) (port: int) (suffix: string) : string =
    prefix + (if enabled then string port else "") + suffix

let referenceFormat (prefix: string) (enabled: bool) (port: int) (suffix: string) : string =
    String.concat "" [ prefix; (if enabled then string port else ""); suffix ]

let trim (x: string) : string = x.Trim()
