package example
import lawspec.data.Shown
object Gadt { fun describe(value: Shown): String = value.witness }
