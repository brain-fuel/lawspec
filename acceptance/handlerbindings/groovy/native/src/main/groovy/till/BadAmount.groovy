package till

/** The application's error for an amount it cannot take. */
@groovy.transform.CompileStatic
class BadAmount extends RuntimeException {
  BadAmount(String message) {
    super(message)
  }
}
