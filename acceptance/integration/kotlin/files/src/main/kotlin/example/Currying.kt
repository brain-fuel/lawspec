package example
object Currying {
 fun sumFour(a: java.math.BigInteger,b: java.math.BigInteger,c: java.math.BigInteger,d: java.math.BigInteger): Number = a+b+c+d
 fun format(prefix: String,enabled: Boolean,port: Int,suffix: String): String = prefix+(if(enabled) port.toString() else "")+suffix
 fun referenceFormat(prefix: String,enabled: Boolean,port: Int,suffix: String): String = listOf(prefix,if(enabled) port.toString() else "",suffix).joinToString("")
 fun trim(x: String): String = x.trim()
}
