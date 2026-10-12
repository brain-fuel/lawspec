package example.mixed

object Inputs {
  def normalize(x: String): String = x.replace(" ", "-")
  def identity(x: Int): Int = x
}
