package example
object CanonicalUrl {
fun canonicalize(x: String): String = x.trimEnd('/')
}
