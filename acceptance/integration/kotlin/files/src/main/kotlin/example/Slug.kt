package example
object Slug {
fun normalize(x: String): String = x.replace(" ", "-")
fun referenceNormalize(x: String): String = x.replace(' ', '-')
}
