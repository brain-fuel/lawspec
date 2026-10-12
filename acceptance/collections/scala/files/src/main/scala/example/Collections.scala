// User-owned LawSpec adapter.
package example

import scala.collection.immutable.Queue

object Collections {
  // (List (Int32) -> lawspec.collections::type::Set (Int32))
  def dedupe(
    value0: scala.collection.immutable.List[scala.Int],
  ): scala.collection.immutable.Set[scala.Int] =
    value0.toSet

  // (List (Text) -> lawspec.collections::type::KeyVal (Text) (BigInt))
  def wordCounts(
    value0: scala.collection.immutable.List[java.lang.String],
  ): scala.collection.immutable.Map[java.lang.String, scala.math.BigInt] =
    value0.groupMapReduce(identity)(_ => BigInt(1))(_ + _)

  // (List (Int8) -> lawspec.collections::type::Queue (Int8))
  def fifo(
    value0: scala.collection.immutable.List[scala.Byte],
  ): scala.collection.immutable.Queue[scala.Byte] =
    Queue.from(value0)

  // A Stack is a List with its top first, so the last value pushed leads.
  // (List (Int8) -> lawspec.collections::type::Stack (Int8))
  def lifo(
    value0: scala.collection.immutable.List[scala.Byte],
  ): scala.collection.immutable.List[scala.Byte] =
    value0.reverse

  // (lawspec.collections::type::Deque (Int8) -> lawspec.collections::type::Deque (Int8))
  def rotate(
    value0: scala.collection.immutable.Vector[scala.Byte],
  ): scala.collection.immutable.Vector[scala.Byte] =
    if (value0.isEmpty) value0 else value0.tail :+ value0.head

  // Lists compare by value, so they can be Set elements directly.
  // (List (List (Int8)) -> lawspec.collections::type::Set (List (Int8)))
  def distinctRows(
    value0: scala.collection.immutable.List[scala.collection.immutable.List[scala.Byte]],
  ): scala.collection.immutable.Set[scala.collection.immutable.List[scala.Byte]] =
    value0.toSet
}
