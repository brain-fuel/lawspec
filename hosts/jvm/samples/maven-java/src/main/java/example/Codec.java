// User-owned LawSpec adapter.

package example;

public final class Codec
{
  // itoa :: (Int32 -> Text) — laws/atoi_codec.lawspec:3
  public static String itoa(int int32_1)
  {
    return Integer.toString(int32_1);
  }

  // atoi :: (Text -> Int32) — laws/atoi_codec.lawspec:4
  public static int atoi(String text1)
  {
    return Integer.parseInt(text1);
  }
}
