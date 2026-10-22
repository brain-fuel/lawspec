// User-owned LawSpec adapter: native handlers of Logs, Reader and Writer that
// share the case's Store.
package example

import lawspec.runtime.LawSpecRuntime

object Composition {
    /** An in-memory log store: each log's records, newest last. */
    class LogStore {
        val logs = mutableMapOf<String, MutableList<String>>()
        var open = true
    }

    // (Unit -> example.composition::type::Store)
    fun openStore(value0: kotlin.Unit): kotlin.Any = LogStore()

    // (example.composition::type::Store -> Unit)
    fun closeStore(value0: kotlin.Any): kotlin.Unit {
        (value0 as LogStore).open = false
    }

    /** The native handler of Logs: create, append. */
    class LogsHandler(val resource: kotlin.Any) : lawspec.abilities.example.Composition.Logs {
        override fun create(value0: kotlin.String) {
            (resource as LogStore).logs[value0] = mutableListOf()
        }
        override fun append(
            value0: kotlin.String,
            value1: kotlin.String,
        ): kotlin.Long {
            val records = (resource as LogStore).logs[value0]
                ?: throw LawSpecRuntime.Fail(lawspec.data.Problem.UnknownLog)
            if (value1.isEmpty()) throw LawSpecRuntime.Fail(lawspec.data.Problem.EmptyRecord)
            records.add(value1)
            return (records.size - 1).toLong()
        }
    }

    /** The native handler of Reader: size. */
    class ReaderHandler(val resource: kotlin.Any) : lawspec.abilities.example.Composition.Reader {
        override fun size(
            value0: kotlin.String,
        ): lawspec.runtime.LawSpecRuntime.Maybe<kotlin.Long> {
            val records = (resource as LogStore).logs[value0] ?: return LawSpecRuntime.Absent()
            return LawSpecRuntime.Present(records.size.toLong())
        }
    }

    /** The native handler of Writer: write, lastOffset. */
    class WriterHandler(val resource: kotlin.Any) : lawspec.abilities.example.Composition.Writer {
        private var last: LawSpecRuntime.Maybe<kotlin.Long> = LawSpecRuntime.Absent()
        override fun write(
            value0: kotlin.String,
            value1: kotlin.String,
        ): kotlin.Boolean {
            val records = (resource as LogStore).logs[value0] ?: return false
            if (value1.isEmpty()) return false
            records.add(value1)
            last = LawSpecRuntime.Present((records.size - 1).toLong())
            return true
        }
        override fun lastOffset(): lawspec.runtime.LawSpecRuntime.Maybe<kotlin.Long> = last
    }
}
