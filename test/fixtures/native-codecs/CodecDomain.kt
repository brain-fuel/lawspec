package domain

object CodecDomain {
    class Parcel<T>(private val item: T) {
        fun unpack(): T = item
    }

    class FlatChain<T>(items: List<T>, private val ended: Boolean) {
        private val items = items.toList()
        fun items(): List<T> = items.toList()
        fun ended(): Boolean = ended
    }

    class Positive(private val value: Byte) {
        fun unpack(): Byte = value
    }

    fun <T> copy(value: T): T = value
}
