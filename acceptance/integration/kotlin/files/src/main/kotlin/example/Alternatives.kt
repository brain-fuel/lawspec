package example
object Alternatives {
fun render(x: Int): String = x.toString()
fun referenceRender(x: Int): String = java.lang.Integer.toString(x)
fun clamp(x: Int): Int = maxOf(0, x)
fun referenceClamp(x: Int): Int = if (x < 0) 0 else x
}
