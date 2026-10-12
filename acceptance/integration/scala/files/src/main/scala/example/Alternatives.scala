package example

object Alternatives {
  def render(x: Int): String = x.toString
  def referenceRender(x: Int): String = java.lang.Integer.toString(x)
  def clamp(x: Int): Int = math.max(0, x)
  def referenceClamp(x: Int): Int = if (x < 0) 0 else x
}
