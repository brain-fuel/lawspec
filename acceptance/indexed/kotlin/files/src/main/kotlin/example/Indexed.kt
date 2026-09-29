// User-owned LawSpec adapter.
package example

import lawspec.data.Tree
import lawspec.data.Vec

object Indexed {
    fun replicate(value0: java.math.BigInteger, value1: Byte): Vec<Byte> {
        var result: Vec<Byte> = Vec.VNilCase()
        var i = java.math.BigInteger.ZERO
        while (i < value0) {
            result = Vec.VConsCase(value1, result)
            i += java.math.BigInteger.ONE
        }
        return result
    }

    fun append(value0: Vec<Byte>, value1: Vec<Byte>): Vec<Byte> =
        if (value0 is Vec.VConsCase) Vec.VConsCase(value0.head, append(value0.tail, value1)) else value1

    fun zip(value0: Vec<Byte>, value1: Vec<Boolean>): Vec<Boolean> =
        if (value0 is Vec.VConsCase && value1 is Vec.VConsCase) {
            Vec.VConsCase(value1.head, zip(value0.tail, value1.tail))
        } else {
            Vec.VNilCase()
        }

    fun flatten(value0: Tree<Byte>): Vec<Byte> {
        if (value0 !is Tree.BinCase) return Vec.VNilCase()
        val right: Vec<Byte> = Vec.VConsCase(value0.value, flatten(value0.right))
        return append(flatten(value0.left), right)
    }
}
