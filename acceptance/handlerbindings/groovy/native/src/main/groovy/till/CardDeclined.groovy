package till

/** The application's error for a declined card. */
@groovy.transform.CompileStatic
class CardDeclined extends RuntimeException {
  CardDeclined() {
    super('declined')
  }
}
