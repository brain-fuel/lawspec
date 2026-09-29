package domain;

import org.jetbrains.jetCheck.Generator;

public final class CodecGenerators {
  private CodecGenerators() {}

  public static <T> Generator<CodecDomain.Parcel<T>> parcels(Generator<T> child) {
    return child.map(CodecDomain.Parcel::new);
  }

  public static Generator<Byte> bytes() {
    return Generator.integers(1, 100).map(Integer::byteValue);
  }

  public static Generator<CodecDomain.Positive> positives() {
    return Generator.integers(1, 100).map(value -> new CodecDomain.Positive(value.byteValue()));
  }
}
