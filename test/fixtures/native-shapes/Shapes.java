package domain;

import java.util.List;
import lawspec.runtime.LawSpecRuntime.Maybe;

public final class Shapes {
  private Shapes() {}

  public record Wrapped<T>(T stored) {}

  public sealed interface Link<T> permits End, Next {}

  public record End<T>() implements Link<T> {}

  public record Next<T>(T item, Maybe<Link<T>> remainder) implements Link<T> {}

  public sealed interface Forest<T> permits Item, Group {}

  public record Item<T>(T datum) implements Forest<T> {}

  public record Group<T>(List<Forest<T>> trees) implements Forest<T> {}

  public record Seal() {}

  public static <T> T copy(T value) {
    return value;
  }
}
