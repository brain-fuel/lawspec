import java.math.BigDecimal
import java.math.BigInteger
import lawspec.data.Tree
import lawspec.data.Architecture
import lawspec.definitions.example.Total
import lawspec.runtime.LawSpecKotlin as Native
import lawspec.runtime.LawSpecRuntime as Runtime

private fun rejected(action: () -> Unit) {
  try {
    action()
    error("invalid native value accepted")
  } catch (expected: IllegalArgumentException) {
    check(expected.message!!.contains("example.total::"))
  }
}

fun main(args: Array<String>) {
  val bits = args[0].toInt()
  val symbols = mutableMapOf<String, Any>()
  check(Total.size(symbols, listOf(1, 2, 3)) == BigInteger.valueOf(3))
  check(Total.forward(symbols, emptyList()) == BigInteger.ZERO)
  check(Total.sumList(symbols, listOf(127, 127)) == BigInteger.valueOf(254))
  check(Total.increment(symbols, 127) == BigInteger.valueOf(128))
  check(!Total.divisible(symbols, BigInteger.ONE, BigInteger.ZERO))
  check(Total.divisible(symbols, BigInteger.valueOf(-6), BigInteger.valueOf(3)))
  check(Total.maybeDefault(symbols, Runtime.Nothing()) == 0.toByte())
  check(Total.maybeDefault(symbols, Runtime.Just(127.toByte())) == 127.toByte())
  val raw = mutableListOf('\ud800', '\u0000', '\uffff')
  val copied = Total.raw(symbols, raw)
  raw[0] = 'a'
  check(copied == listOf('\ud800', '\u0000', '\uffff'))
  check(Total.sumTree(symbols, Tree.BranchCase(Tree.LeafCase(127), Tree.LeafCase(127))) == BigInteger.valueOf(254))
  check(lawspec.definitions.Other.size(symbols, true))
  check(!lawspec.definitions.Other.size(symbols, false))
  val states: List<Native.Optional<Native.Nullable<Byte>>> = listOf(
    Native.Optional.Undefined(),
    Native.Optional.Present(Native.Nullable.Null()),
    Native.Optional.Present(Native.Nullable.Present(0)),
  )
  for (state in states) {
    val result = Total.absent(symbols, state)
    when (state) {
      is Native.Optional.Undefined -> check(result is Native.Optional.Undefined)
      is Native.Optional.Present -> {
        val inner = (result as Native.Optional.Present).value
        when (val expected = state.value) {
          is Native.Nullable.Null -> check(inner is Native.Nullable.Null)
          is Native.Nullable.Present -> check((inner as Native.Nullable.Present).value == expected.value)
        }
      }
    }
  }
  check(Total.symbol(symbols, Unit) == Total.symbol(symbols, Unit))
  check(Total.symbol(mutableMapOf(), Unit) != Total.symbol(symbols, Unit))
  check(Total.exact(symbols, BigDecimal("0.1")).compareTo(BigDecimal("0.3")) == 0)
  check((Total.either(symbols, Runtime.Left(127.toByte())) as Runtime.Left<Byte, Boolean>).value() == 127.toByte())
  check((Total.either(symbols, Runtime.Right(true)) as Runtime.Right<Byte, Boolean>).value())
  val maximum = BigInteger.ONE.shiftLeft(bits - 1).subtract(BigInteger.ONE)
  check(Total.machine(symbols, maximum) == maximum)
  rejected { Total.machine(symbols, maximum + BigInteger.ONE) }
  check(Total.architecture(symbols, Architecture.UnusedCase()) is Architecture.UnusedCase)
  check((Total.architecture(symbols, Architecture.NativeCase(maximum)) as Architecture.NativeCase).size == maximum)
  rejected { Total.architecture(symbols, Architecture.NativeCase(maximum + BigInteger.ONE)) }
  println("Kotlin standalone definition calls passed: $bits")
}
