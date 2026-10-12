package example

object Slug {
  def normalize(x: String): String = x.replace(" ", "-")
  def referenceNormalize(x: String): String = x.replace(' ', '-')
}
