// User-owned LawSpec adapter. 
import LawSpecRuntime

extension Example.Algebra {
    static func add(_ x: BigInt, _ y: BigInt) -> BigInt { x + y }
    static func multiply(_ x: BigInt, _ y: BigInt) -> BigInt { x * y }
    static func negateValue(_ x: BigInt) -> BigInt { -x }
    static func maximumValue(_ x: BigInt, _ y: BigInt) -> BigInt { BigInt.max(x, y) }
    static func subtractValue(_ x: BigInt, _ y: BigInt) -> BigInt { x - y }
    static func divideLeft(_ x: BigInt, _ y: BigInt) -> BigInt { x - y }
    static func divideRight(_ x: BigInt, _ y: BigInt) -> BigInt { x + y }
}
