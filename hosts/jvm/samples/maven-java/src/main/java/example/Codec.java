// User-owned LawSpec adapter.

package example;

/**
 * The sample's native codec: the Java binding of {@code itoa} and {@code atoi}, which
 * laws/atoi_codec.lawspec declares and states a law about.
 */
public final class Codec
{
  /**
   * The native binding of {@code itoa :: (Int32 -> Text)}, laws/atoi_codec.lawspec:3.
   *
   * @param int32_1 the integer
   * @return its decimal text
   */
  public static String itoa(int int32_1)
  {
    return Integer.toString(int32_1);
  }

  /**
   * The native binding of {@code atoi :: (Text -> Int32)}, laws/atoi_codec.lawspec:4.
   *
   * @param text1 decimal text
   * @return the integer it reads as
   */
  public static int atoi(String text1)
  {
    return Integer.parseInt(text1);
  }
}
