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
 * The hash mask is the BLAKE3 keyed hash (the BLAKE3 specification, section 2). Its key is 32
 * secret bytes the application sets when it starts; LawSpec never writes a key into generated code
 * and has no default, so a rendering without a key throws.
 *
 * <p>
 * The digest mask is the BLAKE3 hash and needs no key: it hides a value from a reader, and not
 * from someone who can guess candidates and hash each one.
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
  public static void setMaskHashKey(byte[] key)
  {
    if (key == null || key.length != 32)
    {
      throw new IllegalArgumentException("LawSpec masking: the hash key is 32 bytes");
    }
    hashKey = key.clone();
  }

  /**
   * The word hash, a colon and the BLAKE3 keyed hash of the text's UTF-8 bytes, under the key the
   * application set: equal values show alike, and the value cannot be found without the key, even
   * by trying candidates. A lone surrogate is hashed as U+FFFD.
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
              + " LawSpecMasks.setMaskHashKey with 32 secret bytes when the application starts");
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

  /**
   * The word digest, a colon and the BLAKE3 hash of the text's UTF-8 bytes: LawSpec's {@code
   * maskDigestBlake3 text}, and what b3sum prints for the same bytes. It needs no key, so whoever
   * can guess the text can check the guess. A lone surrogate is hashed as U+FFFD.
   */
  public static String maskDigestBlake3(String value)
  {
    return LawSpecRuntime.maskDigestBlake3(value);
  }

  /** The digest mask of this version's default algorithm, BLAKE3. */
  public static String maskDigest(String value)
  {
    return maskDigestBlake3(value);
  }

  /**
   * The digest of a text within a context, by BLAKE3's key derivation: LawSpec's {@code
   * maskDigestBlake3In context text}. A field shown as digest is rendered in the context {@code
   * <unit>.<Record>.<field>}, so one text has unrelated digests in two fields.
   */
  public static String maskDigestBlake3In(String context, String value)
  {
    return LawSpecRuntime.maskDigestBlake3In(context, value);
  }

  /** As maskDigestBlake3In, for this version's default algorithm. */
  public static String maskDigestIn(String context, String value)
  {
    return maskDigestBlake3In(context, value);
  }
}
