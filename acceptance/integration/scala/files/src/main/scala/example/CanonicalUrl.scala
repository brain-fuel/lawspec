package example

object CanonicalUrl {
  def canonicalize(x: String): String = x.reverse.dropWhile(_ == '/').reverse
}
