package example
import lawspec.data.Shown
@groovy.transform.CompileStatic
final class Gadt { static String describe(Shown value) { return value.witness() } }
