// User-owned LawSpec adapter.

package example;

public final class AtoiCodec
{
  // itoa :: (Int32 -> Text) — atoi_codec.lawspec:3
  public static String itoa(int value0)
  {
    throw new UnsupportedOperationException("itoa -> Text");
  }

  // atoi :: (Text -> Int32) — atoi_codec.lawspec:4
  public static int atoi(String value0)
  {
    throw new UnsupportedOperationException("atoi -> Int32");
  }
}
