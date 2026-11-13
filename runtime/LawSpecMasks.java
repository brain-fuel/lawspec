package lawspec.runtime;

/**
 * The masks of a masking block, for a record's native rendering.
 *
 * <p>
 * A generated record with a masking block overrides {@code toString()} with these, so a logger or a
 * string concatenation shows what the block allows. They follow the checked definitions of the
 * built-in unit lawspec.rules (rulesMaskLast, rulesMaskEmail), which every generated test suite
 * checks; the contracts-masking acceptance suite compares the two renderings.
 *
 * <p>
 * The hash mask is keyed BLAKE3-256 (the BLAKE3 specification, section 2.1). Its key is 32 secret
 * bytes the application sets when it starts; LawSpec never writes a key into generated code and has
 * no default, so a rendering without a key throws.
 */
public final class LawSpecMasks
{
  private LawSpecMasks()
  {
  }

  /** What a hidden value shows. */
  public static final String HIDDEN = "***";

  /** What a hidden value shows: three stars, whatever the value. */
  public static String maskStar(Object value)
  {
    return HIDDEN;
  }

  /** Three stars and the last characters; a text no longer than that is not shown at all. */
  public static String maskLast(int count, String value)
  {
    if (value == null)
    {
      return HIDDEN;
    }
    int length = value.codePointCount(0, value.length());
    if (length <= count)
    {
      return HIDDEN;
    }
    return HIDDEN + value.substring(value.offsetByCodePoints(0, length - count));
  }

  /**
   * The first character before the first at sign, three stars, and what follows the last at sign; a
   * text without an at sign is not shown at all.
   */
  public static String maskEmail(String value)
  {
    if (value == null)
    {
      return HIDDEN;
    }
    int first = value.indexOf('@');
    if (first < 0)
    {
      return HIDDEN;
    }
    String name = value.substring(0, first);
    String shown = name.isEmpty() ? "" : name.substring(0, name.offsetByCodePoints(0, 1));
    return shown + HIDDEN + "@" + value.substring(value.lastIndexOf('@') + 1);
  }

  private static volatile byte[] hashKey;

  /**
   * Sets the key of the hash mask: 32 secret bytes the application loads when it starts.
   *
   * @throws IllegalArgumentException when the key is not 32 bytes
   */
  public static void setHashKey(byte[] key)
  {
    if (key == null || key.length != 32)
    {
      throw new IllegalArgumentException("LawSpec masking: the hash key is 32 bytes");
    }
    hashKey = key.clone();
  }

  /**
   * The word hash, a colon and the keyed BLAKE3-256 digest of the text's UTF-8 bytes, under the key
   * the application set: equal values show alike, and the value cannot be read back without the
   * key. A lone surrogate is hashed as U+FFFD.
   *
   * @throws IllegalStateException when no key is set; it never falls back to showing or hiding
   */
  public static String maskHashBlake3(String value)
  {
    byte[] key = hashKey;
    if (key == null)
    {
      throw new IllegalStateException(
          "LawSpec masking: a field is shown as hash and no key is set; call"
              + " LawSpecMasks.setHashKey with 32 secret bytes when the application starts");
    }
    return LawSpecRuntime.maskHashBlake3With(key, value);
  }

  /**
   * The hash mask of this version's default algorithm, BLAKE3. A version that changes the default
   * says so as a breaking change; name the algorithm (maskHashBlake3) where the digests must stay
   * comparable.
   */
  public static String maskHash(String value)
  {
    return maskHashBlake3(value);
  }

  /**
   * maskHashBlake3 under a key given with the call: LawSpec's own {@code maskHashBlake3 key text},
   * which is pure.
   *
   * @throws IllegalArgumentException when the key is not 32 bytes
   */
  public static String maskHashBlake3With(byte[] key, String value)
  {
    return LawSpecRuntime.maskHashBlake3With(key, value);
  }

  /** As maskHash, under a key given with the call. */
  public static String maskHashWith(byte[] key, String value)
  {
    return maskHashBlake3With(key, value);
  }
}
