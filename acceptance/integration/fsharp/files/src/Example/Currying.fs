// User-owned LawSpec adapter.
module Example.Currying

let sumFour (a: bigint) (b: bigint) (c: bigint) (d: bigint) : bigint = a + b + c + d
let format (prefix: string) (enabled: bool) (port: int) (suffix: string) : string =
    prefix + (if enabled then string port else "") + suffix
let referenceFormat (prefix: string) (enabled: bool) (port: int) (suffix: string) : string =
    System.String.Join("", [ prefix; (if enabled then port.ToString() else ""); suffix ])
let trim (x: string) : string = x.Trim()
