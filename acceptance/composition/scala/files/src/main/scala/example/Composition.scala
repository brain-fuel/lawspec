// User-owned LawSpec adapter: native handlers of Logs, Reader and Writer that
// share the case's Store.
package example

import scala.collection.mutable

object Composition {
  /** An in-memory log store: each log's records, newest last. */
  final class LogStore {
    val logs: mutable.Map[String, mutable.ArrayBuffer[String]] = mutable.Map.empty
    var open: Boolean = true
  }

  // (Unit -> example.composition::type::Store)
  def openStore(value0: scala.Unit): scala.Any = LogStore()

  // (example.composition::type::Store -> Unit)
  def closeStore(value0: scala.Any): scala.Unit =
    value0.asInstanceOf[LogStore].open = false

  /** The native handler of Logs: create, append. */
  class LogsHandler(val resource: scala.Any) extends lawspec.abilities.example.Composition.Logs {
    private def store = resource.asInstanceOf[LogStore]

    override def create(value0: java.lang.String): scala.Unit =
      store.logs(value0) = mutable.ArrayBuffer.empty

    override def append(
      value0: java.lang.String,
      value1: java.lang.String,
    ): scala.util.Either[lawspec.data.Problem, scala.Long] =
      store.logs.get(value0) match {
        case None => Left(lawspec.data.Problem.UnknownLog)
        case Some(_) if value1.isEmpty => Left(lawspec.data.Problem.EmptyRecord)
        case Some(records) =>
          records += value1
          Right((records.size - 1).toLong)
      }
  }

  /** The native handler of Reader: size. */
  class ReaderHandler(val resource: scala.Any) extends lawspec.abilities.example.Composition.Reader {
    override def size(
      value0: java.lang.String,
    ): scala.Option[scala.Long] =
      resource.asInstanceOf[LogStore].logs.get(value0).map(_.size.toLong)
  }

  /** The native handler of Writer: write, lastOffset. */
  class WriterHandler(val resource: scala.Any) extends lawspec.abilities.example.Composition.Writer {
    private var last: scala.Option[scala.Long] = None

    override def write(
      value0: java.lang.String,
      value1: java.lang.String,
    ): scala.Boolean =
      resource.asInstanceOf[LogStore].logs.get(value0) match {
        case Some(records) if value1.nonEmpty =>
          records += value1
          last = Some((records.size - 1).toLong)
          true
        case _ => false
      }

    override def lastOffset(): scala.Option[scala.Long] = last
  }
}
