// User-owned LawSpec adapter.
package example

import lawspec.data.Tree
import lawspec.data.Vec

object Indexed {
    fun replicate(value0: java.math.BigInteger, value1: Byte): Vec<Byte> {
        var result: Vec<Byte> = Vec.VNil()
        var i = java.math.BigInteger.ZERO
        while (i < value0) {
            result = Vec.VCons(lawspec.data.VConsDetails(value1, result))
            i += java.math.BigInteger.ONE
        }
        return result
    }

    fun append(value0: Vec<Byte>, value1: Vec<Byte>): Vec<Byte> =
        if (value0 is Vec.VCons)
            Vec.VCons(
                lawspec.data.VConsDetails(value0.value.head, append(value0.value.tail, value1))
            )
        else value1

    fun zip(value0: Vec<Byte>, value1: Vec<Boolean>): Vec<Boolean> =
        if (value0 is Vec.VCons && value1 is Vec.VCons) {
            Vec.VCons(
                lawspec.data.VConsDetails(
                    value1.value.head,
                    zip(value0.value.tail, value1.value.tail),
                )
            )
        } else {
            Vec.VNil()
        }

    fun flatten(value0: Tree<Byte>): Vec<Byte> {
        if (value0 !is Tree.Bin) return Vec.VNil()
        val right: Vec<Byte> =
            Vec.VCons(lawspec.data.VConsDetails(value0.value.value, flatten(value0.value.right)))
        return append(flatten(value0.value.left), right)
    }
}
