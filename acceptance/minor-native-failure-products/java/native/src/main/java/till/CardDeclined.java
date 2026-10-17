package till;

/** The application's error for a declined card. */
public class CardDeclined extends RuntimeException {
  public CardDeclined() {
    super("declined");
  }
}
