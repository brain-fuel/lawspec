package lawspec.runtime;

/**
 * A logging argument that is rendered masked, and only when the logger asks for it.
 *
 * <p>{@code log.info("placed {}", LawSpecMasked.of(order))} prints the order as its masking block
 * shows it. A generated record with a masking block already renders itself masked, so the wrapper
 * matters for what holds such records: an array or a nested array is rendered element by element
 * instead of as a type and an address, and null is the text {@code null}. The wrapper holds the
 * value itself; nothing is rendered when the level is off. It needs no logging library.
 */
public final class LawSpecMasked
{
  private final Object value;

  private LawSpecMasked(Object value)
  {
    this.value = value;
  }

  /** The value as an argument for a logger. */
  public static LawSpecMasked of(Object value)
  {
    return new LawSpecMasked(value);
  }

  /** The rendering a log may hold: masked records by their masking blocks. */
  public static String render(Object value)
  {
    if (value instanceof LawSpecMasked wrapped)
    {
      return render(wrapped.value);
    }
    if (value instanceof Object[] items)
    {
      var shown = new StringBuilder("[");
      for (int i = 0; i < items.length; i++)
      {
        shown.append(i == 0 ? "" : ", ").append(render(items[i]));
      }
      return shown.append(']').toString();
    }
    return String.valueOf(value);
  }

  @Override
  public String toString()
  {
    return render(value);
  }
}
