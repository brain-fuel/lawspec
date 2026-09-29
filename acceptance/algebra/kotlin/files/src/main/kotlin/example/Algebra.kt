package example
import java.math.BigInteger
object Algebra {
 fun add(x: BigInteger,y: BigInteger): Number = x+y
 fun multiply(x: BigInteger,y: BigInteger): Number = x*y
 fun negateValue(x: BigInteger): Number = -x
 fun maximumValue(x: BigInteger,y: BigInteger): Number = maxOf(x,y)
 fun subtractValue(x: BigInteger,y: BigInteger): Number = x-y
 fun divideLeft(x: BigInteger,y: BigInteger): Number = x-y
 fun divideRight(x: BigInteger,y: BigInteger): Number = x+y
}
