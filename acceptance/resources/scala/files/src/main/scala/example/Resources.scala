// User-owned LawSpec adapters for the resources example.
package example

import java.net.InetAddress
import java.net.ServerSocket
import java.nio.file.Files
import java.nio.file.Path
import scala.collection.mutable

object Resources {
  /** An in-memory store. At most three may be open at once, so a store
    * that is never closed is noticed. */
  final class Store {
    val items = mutable.Map[Int, Int]()
    var open = true

    if (openCount >= 3) throw IllegalStateException("too many open stores: one was never closed")
    openCount += 1

    def close(): Unit =
      if (open) {
        open = false
        openCount -= 1
      }
  }

  private var openCount = 0

  private def check(condition: Boolean, message: String): Unit =
    if (!condition) throw IllegalStateException(message)

  // (Unit -> example.resources::type::Store)
  def openStore(value0: Unit): Any = Store()

  // (example.resources::type::Store -> Unit)
  def closeStore(value0: Any): Unit = value0.asInstanceOf[Store].close()

  // (example.resources::type::Store -> Unit)
  def clearStore(value0: Any): Unit = value0.asInstanceOf[Store].items.clear()

  // (example.resources::type::Store -> (Int32 -> (Int32 -> Unit)))
  def put(value0: Any, value1: Int, value2: Int): Unit = {
    val store = value0.asInstanceOf[Store]
    check(store.open, "the store is closed")
    store.items(value1) = value2
  }

  // (example.resources::type::Store -> (Int32 -> Maybe (Int32)))
  def get(value0: Any, value1: Int): Option[Int] = {
    val store = value0.asInstanceOf[Store]
    check(store.open, "the store is closed")
    store.items.get(value1)
  }

  // (example.resources::type::Store -> Bool)
  def isOpen(value0: Any): Boolean = value0.asInstanceOf[Store].open

  // (example.resources::type::Store -> Int32)
  def size(value0: Any): Int = value0.asInstanceOf[Store].items.size

  // (Text -> (Int32 -> Unit))
  def writeNote(value0: String, value1: Int): Unit = {
    Files.writeString(Path.of(value0, "note.txt"), value1.toString)
  }

  // (Text -> Maybe (Int32))
  def readNote(value0: String): Option[Int] = {
    val note = Path.of(value0, "note.txt")
    if (Files.exists(note)) Some(Files.readString(note).toInt) else None
  }

  // (Int32 -> Bool)
  def canListen(value0: Int): Boolean =
    try {
      val socket = ServerSocket(value0, 1, InetAddress.getLoopbackAddress())
      socket.close()
      true
    } catch {
      case _: java.io.IOException => false
    }

  // (Int32 -> Unit)
  def setGreeting(value0: Int): Unit = {
    System.setProperty("lawspec.example.greeting", value0.toString)
  }

  // (Unit -> Maybe (Int32))
  def greeting(value0: Unit): Option[Int] =
    Option(System.getProperty("lawspec.example.greeting")).map(_.toInt)

  // A pool that is costly to open: this JVM may open only one, so the suite
  // passes only if the harness shares it (share Pool per unit).
  private var poolsOpened = 0

  final class Pool {
    var amount = 0
    var open = true
  }

  // (Unit -> example.resources::type::Pool)
  def openPool(value0: Unit): Any = {
    check(poolsOpened < 1, "a second pool was opened: the harness should share it")
    poolsOpened += 1
    Pool()
  }

  // (example.resources::type::Pool -> Unit)
  def drainPool(value0: Any): Unit = {
    value0.asInstanceOf[Pool].amount = 0
  }

  // (example.resources::type::Pool -> Unit)
  def closePool(value0: Any): Unit = {
    value0.asInstanceOf[Pool].open = false
  }

  // (example.resources::type::Pool -> (Int32 -> Unit))
  def fill(value0: Any, value1: Int): Unit = {
    val pool = value0.asInstanceOf[Pool]
    check(pool.open, "the pool is closed")
    pool.amount += value1
  }

  // (example.resources::type::Pool -> Int32)
  def level(value0: Any): Int = value0.asInstanceOf[Pool].amount
}
