// User-owned LawSpec adapter: the portable generator under test.
package example

import lawspec.runtime.LawSpecRuntime
import scala.jdk.CollectionConverters.*

object Generation {
  // (Text -> (UInt64 -> (Int32 -> (Int32 -> List (Text)))))
  def generated(
    value0: java.lang.String,
    value1: scala.math.BigInt,
    value2: scala.Int,
    value3: scala.Int,
  ): scala.collection.immutable.List[java.lang.String] =
    LawSpecRuntime.generated(value0, value1.toLong, value2.toLong, value3.toLong).asScala.toList

  // (Text -> (UInt64 -> (Int32 -> List (Text))))
  def shrunk(
    value0: java.lang.String,
    value1: scala.math.BigInt,
    value2: scala.Int,
  ): scala.collection.immutable.List[java.lang.String] =
    LawSpecRuntime.shrunk(value0, value1.toLong, value2.toLong).asScala.toList
}
