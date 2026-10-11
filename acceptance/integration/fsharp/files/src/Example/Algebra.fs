// User-owned LawSpec adapter.
module Example.Algebra

let add (x: bigint) (y: bigint) : bigint = x + y
let multiply (x: bigint) (y: bigint) : bigint = x * y
let negateValue (x: bigint) : bigint = -x
let maximumValue (x: bigint) (y: bigint) : bigint = max x y
let subtractValue (x: bigint) (y: bigint) : bigint = x - y
let divideLeft (x: bigint) (y: bigint) : bigint = x - y
let divideRight (x: bigint) (y: bigint) : bigint = x + y
