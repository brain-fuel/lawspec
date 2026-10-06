// User-owned LawSpec adapters for the resources example.
package example

import java.net.InetAddress
import java.net.ServerSocket
import java.nio.file.Files
import java.nio.file.Path
import lawspec.runtime.LawSpecRuntime

object Resources {
    /** An in-memory store. At most three may be open at once, so a store
     * that is never closed is noticed. */
    class Store {
        val items = mutableMapOf<Int, Int>()
        var open = true

        init {
            check(openCount < 3) { "too many open stores: one was never closed" }
            openCount++
        }

        fun close() {
            if (open) {
                open = false
                openCount--
            }
        }
    }

    private var openCount = 0

    private fun <T> maybe(value: T?): LawSpecRuntime.Maybe<T> =
        if (value == null) LawSpecRuntime.Nothing() else LawSpecRuntime.Just(value)

    // (Unit -> example.resources::type::Store)
    fun openStore(value0: kotlin.Unit): kotlin.Any = Store()

    // (example.resources::type::Store -> Unit)
    fun closeStore(value0: kotlin.Any): kotlin.Unit = (value0 as Store).close()

    // (example.resources::type::Store -> Unit)
    fun clearStore(value0: kotlin.Any): kotlin.Unit = (value0 as Store).items.clear()

    // (example.resources::type::Store -> (Int32 -> (Int32 -> Unit)))
    fun put(value0: kotlin.Any, value1: kotlin.Int, value2: kotlin.Int): kotlin.Unit {
        val store = value0 as Store
        check(store.open) { "the store is closed" }
        store.items[value1] = value2
    }

    // (example.resources::type::Store -> (Int32 -> Maybe (Int32)))
    fun get(
        value0: kotlin.Any,
        value1: kotlin.Int,
    ): lawspec.runtime.LawSpecRuntime.Maybe<kotlin.Int> {
        val store = value0 as Store
        check(store.open) { "the store is closed" }
        return maybe(store.items[value1])
    }

    // (example.resources::type::Store -> Bool)
    fun isOpen(value0: kotlin.Any): kotlin.Boolean = (value0 as Store).open

    // (example.resources::type::Store -> Int32)
    fun size(value0: kotlin.Any): kotlin.Int = (value0 as Store).items.size

    // (Text -> (Int32 -> Unit))
    fun writeNote(value0: kotlin.String, value1: kotlin.Int): kotlin.Unit {
        Files.writeString(Path.of(value0, "note.txt"), value1.toString())
    }

    // (Text -> Maybe (Int32))
    fun readNote(value0: kotlin.String): lawspec.runtime.LawSpecRuntime.Maybe<kotlin.Int> {
        val note = Path.of(value0, "note.txt")
        return maybe(if (Files.exists(note)) Files.readString(note).toInt() else null)
    }

    // (Int32 -> Bool)
    fun canListen(value0: kotlin.Int): kotlin.Boolean =
        try {
            ServerSocket(value0, 1, InetAddress.getLoopbackAddress()).use { true }
        } catch (e: java.io.IOException) {
            false
        }

    // (Int32 -> Unit)
    fun setGreeting(value0: kotlin.Int): kotlin.Unit {
        System.setProperty("lawspec.example.greeting", value0.toString())
    }

    // (Unit -> Maybe (Int32))
    fun greeting(value0: kotlin.Unit): lawspec.runtime.LawSpecRuntime.Maybe<kotlin.Int> =
        maybe(System.getProperty("lawspec.example.greeting")?.toInt())
}
