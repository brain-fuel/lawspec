package domain;

import java.util.List;

public final class CodecDomain {
  private CodecDomain() {}

  public static final class Parcel<T> {
    private final T item;
    public Parcel(T item) { this.item = item; }
    public T unpack() { return item; }
  }

  public static final class FlatChain<T> {
    private final List<T> items;
    private final boolean ended;
    public FlatChain(List<T> items, boolean ended) {
      this.items = List.copyOf(items);
      this.ended = ended;
    }
    public List<T> items() { return items; }
    public boolean ended() { return ended; }
  }

  public static final class Positive {
    private final byte value;
    public Positive(byte value) { this.value = value; }
    public byte unpack() { return value; }
  }

  public static <T> T copy(T value) { return value; }
}
