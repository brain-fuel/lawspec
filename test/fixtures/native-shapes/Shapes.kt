package domain

object Shapes {
    data class Wrapped<T>(val stored: T)
    sealed interface Link<T>
    class End<T> : Link<T>
    data class Next<T>(val item: T, val remainder: lawspec.runtime.LawSpecRuntime.Maybe<Link<T>>) : Link<T>
    sealed interface Forest<T>
    data class Item<T>(val datum: T) : Forest<T>
    data class Group<T>(val trees: List<Forest<T>>) : Forest<T>
    class Seal

    fun <T> copy(value: T): T = value
}
