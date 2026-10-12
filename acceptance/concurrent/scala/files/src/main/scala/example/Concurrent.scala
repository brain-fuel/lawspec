// User-owned LawSpec adapter: a queue, a set and a map shared between
// threads, each one of the JVM's own concurrent structures.
package example

import java.util.concurrent.{ConcurrentHashMap, ConcurrentLinkedQueue}
import java.util.concurrent.atomic.AtomicInteger
import lawspec.data.{Cache, Tags, WorkQueue}
import scala.concurrent.Future

object Concurrent {
  private val ids = AtomicInteger()
  private val queues = ConcurrentHashMap[Int, ConcurrentLinkedQueue[java.lang.Integer]]()
  private val sets = ConcurrentHashMap[Int, java.util.Set[Int]]()
  private val maps = ConcurrentHashMap[Int, ConcurrentHashMap[java.lang.Byte, java.lang.Long]]()

  // A structure by its handle; generated tests may name one first.
  private def queue(handle: WorkQueue): ConcurrentLinkedQueue[java.lang.Integer] =
    queues.computeIfAbsent(handle.id, _ => ConcurrentLinkedQueue())

  private def set(handle: Tags): java.util.Set[Int] =
    sets.computeIfAbsent(handle.id, _ => ConcurrentHashMap.newKeySet())

  private def map(handle: Cache): ConcurrentHashMap[java.lang.Byte, java.lang.Long] =
    maps.computeIfAbsent(handle.id, _ => ConcurrentHashMap())

  // (Unit -> example.concurrent::type::WorkQueue)
  def newQueue(value0: scala.Unit): lawspec.data.WorkQueue = {
    val handle = WorkQueue(ids.incrementAndGet())
    queue(handle)
    handle
  }

  // (example.concurrent::type::WorkQueue -> (Int32 -> Unit))
  def offer(
    value0: lawspec.data.WorkQueue,
    value1: scala.Int,
  ): scala.concurrent.Future[scala.Unit] =
    Future.successful { queue(value0).offer(value1); () }

  // (example.concurrent::type::WorkQueue -> Maybe (Int32))
  def poll(value0: lawspec.data.WorkQueue): scala.concurrent.Future[scala.Option[scala.Int]] =
    Future.successful {
      val q = queue(value0)
      Option(q.poll()).map(_.intValue)
    }

  // (example.concurrent::type::WorkQueue -> Int64)
  def queueSize(value0: lawspec.data.WorkQueue): scala.concurrent.Future[scala.Long] =
    Future.successful(queue(value0).size.toLong)

  // (Unit -> example.concurrent::type::Tags)
  def newTags(value0: scala.Unit): lawspec.data.Tags = {
    val handle = Tags(ids.incrementAndGet())
    set(handle)
    handle
  }

  // (example.concurrent::type::Tags -> (Int32 -> Bool))
  def tag(value0: lawspec.data.Tags, value1: scala.Int): scala.concurrent.Future[scala.Boolean] =
    Future.successful(set(value0).add(value1))

  // (example.concurrent::type::Tags -> (Int32 -> Bool))
  def untag(value0: lawspec.data.Tags, value1: scala.Int): scala.concurrent.Future[scala.Boolean] =
    Future.successful(set(value0).remove(value1))

  // (example.concurrent::type::Tags -> (Int32 -> Bool))
  def tagged(value0: lawspec.data.Tags, value1: scala.Int): scala.concurrent.Future[scala.Boolean] =
    Future.successful(set(value0).contains(value1))

  // (Unit -> example.concurrent::type::Cache)
  def newCache(value0: scala.Unit): lawspec.data.Cache = {
    val handle = Cache(ids.incrementAndGet())
    map(handle)
    handle
  }

  // (example.concurrent::type::Cache -> (Int8 -> (Int64 -> Maybe (Int64))))
  def store(
    value0: lawspec.data.Cache,
    value1: scala.Byte,
    value2: scala.Long,
  ): scala.concurrent.Future[scala.Option[scala.Long]] =
    Future.successful(Option(map(value0).put(value1, value2)).map(_.longValue))

  // (example.concurrent::type::Cache -> (Int8 -> Maybe (Int64)))
  def fetch(
    value0: lawspec.data.Cache,
    value1: scala.Byte,
  ): scala.concurrent.Future[scala.Option[scala.Long]] =
    Future.successful(Option(map(value0).get(value1)).map(_.longValue))

  // (example.concurrent::type::Cache -> (Int8 -> Maybe (Int64)))
  def evict(
    value0: lawspec.data.Cache,
    value1: scala.Byte,
  ): scala.concurrent.Future[scala.Option[scala.Long]] =
    Future.successful(Option(map(value0).remove(value1)).map(_.longValue))
}
