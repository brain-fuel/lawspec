package lawspec.runtime;

/**
 * The masks of a masking block, for a record's native rendering.
 *
 * <p>A generated record with a masking block overrides {@code toString()} with these, so a logger
 * or a string concatenation shows what the block allows. They follow the checked definitions of
 * the built-in unit lawspec.rules (rulesMaskLast, rulesMaskEmail), which every generated test
 * suite checks; the contracts-masking acceptance suite compares the two renderings.
 */
public final class LawSpecMasks
{
  private LawSpecMasks()
  {
  }

  /** What a hidden value shows. */
  public static final String HIDDEN = "***";

  /** Three stars and the last characters; a text no longer than that is not shown at all. */
  public static String last(int count, String value)
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
   * The first character before the first at sign, three stars, and what follows the last at
   * sign; a text without an at sign is not shown at all.
   */
  public static String email(String value)
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
}
