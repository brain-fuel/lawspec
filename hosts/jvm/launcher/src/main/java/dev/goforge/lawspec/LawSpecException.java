package dev.goforge.lawspec;

/** A failure to find, unpack, verify or run the native lawspec. */
public class LawSpecException extends RuntimeException
{
  private static final long serialVersionUID = 1L;

  /**
   * Creates an exception with a message.
   *
   * @param message what failed
   */
  public LawSpecException(String message)
  {
    super(message);
  }

  /**
   * Creates an exception with a message and a cause.
   *
   * @param message what failed
   * @param cause the underlying failure
   */
  public LawSpecException(String message, Throwable cause)
  {
    super(message, cause);
  }
}
