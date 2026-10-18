package example
object Gadt { def describe(value: lawspec.data.Shown): String = value.witness }
