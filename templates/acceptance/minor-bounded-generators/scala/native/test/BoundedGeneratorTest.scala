package lawspec

import java.math.BigInteger
import lawspec.runtime.LawSpecRuntime
import lawspec.testing.{Arb, LawSpecScalars, Rng, Tree}
import org.scalatest.funsuite.AnyFunSuite

private case class RangeCase(
  name: String, bits: Int, lower: BigInteger, upper: BigInteger,
  generator: Arb[LawSpecRuntime.Value],
)

private val MachineBits = 64

class BoundedGeneratorTest extends AnyFunSuite:
  private val cases = List(
    //@ scala-bounded-generators
  )

  for entry <- cases do
    test(s"range and shrink bounds ${entry.name}/${entry.bits}/${entry.lower}/${entry.upper}") {
      def checkValue(value: LawSpecRuntime.Value): BigInteger =
        LawSpecRuntime.validate(entry.name, value, entry.bits)
        val integer = value.data().asInstanceOf[BigInteger]
        assert(integer.compareTo(entry.lower) >= 0 && integer.compareTo(entry.upper) <= 0,
          s"outside range: $integer")
        integer
      val seen = scala.collection.mutable.Set.empty[BigInteger]
      var shrinks = 0
      for seed <- 0L until 200L do
        val tree = entry.generator.sample(Rng(seed))
        val value = checkValue(tree.value)
        seen += value
        assert(value == checkValue(entry.generator.sample(Rng(seed)).value))
        if entry.name == "Int64" && entry.lower == BigInteger.ONE.shiftLeft(63).negate() &&
          entry.upper == BigInteger.ONE.shiftLeft(63).subtract(BigInteger.ONE) then
          var leaf = tree
          var depth = 0
          while leaf.children.nonEmpty && depth < 128 do
            leaf = leaf.children.head
            depth += 1
          assert(depth < 128)
          assert(checkValue(leaf.value) == BigInteger.ZERO, "default signed shrinking must reach zero")
        var pending = List(tree)
        for _ <- 0 until 96 if pending.nonEmpty do
          val node = pending.head
          checkValue(node.value)
          val children = node.children.take(6).toList
          shrinks += children.size
          pending = children ++ pending.tail
      if entry.lower != entry.upper then
        assert(seen.size > 1, "generator only produced one value")
        assert(shrinks > 0, "generator lost its shrink tree")
    }
