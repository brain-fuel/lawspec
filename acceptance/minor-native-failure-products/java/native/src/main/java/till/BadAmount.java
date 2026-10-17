package till;

/** The application's error for an amount it cannot take. */
public class BadAmount extends RuntimeException {
  public BadAmount(String message) {
    super(message);
  }
}
