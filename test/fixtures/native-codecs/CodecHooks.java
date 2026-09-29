package domain;

import java.util.ArrayList;
import java.util.function.Function;
import lawspec.data.Parcel;
import lawspec.data.Chain;
import lawspec.data.Positive;
import lawspec.runtime.LawSpecRuntime;

public final class CodecHooks {
  private CodecHooks() {}

  public static <A, B> CodecDomain.Parcel<B> to_parcel(Parcel<A> value, Function<A, B> convert) {
    var item = ((Parcel.ParcelCase<A>) value).item;
    return new CodecDomain.Parcel<>(convert.apply(item));
  }

  public static <A, B> Parcel<A> from_parcel(CodecDomain.Parcel<B> value, Function<B, A> convert) {
    return new Parcel.ParcelCase<>(convert.apply(value.unpack()));
  }

  public static <A, B> CodecDomain.FlatChain<B> to_chain(Chain<A> value, Function<A, B> convert) {
    var items = new ArrayList<B>();
    while (value instanceof Chain.MoreCase<A> more) {
      items.add(convert.apply(more.item));
      if (more.tail instanceof LawSpecRuntime.Nothing<Chain<A>>) {
        return new CodecDomain.FlatChain<>(items, false);
      }
      value = ((LawSpecRuntime.Just<Chain<A>>) more.tail).value();
    }
    return new CodecDomain.FlatChain<>(items, true);
  }

  public static <A, B> Chain<A> from_chain(CodecDomain.FlatChain<B> value, Function<B, A> convert) {
    LawSpecRuntime.Maybe<Chain<A>> tail = value.ended()
        ? new LawSpecRuntime.Just<>(new Chain.StopCase<>()) : new LawSpecRuntime.Nothing<>();
    for (var item : value.items().reversed()) {
      tail = new LawSpecRuntime.Just<>(new Chain.MoreCase<>(convert.apply(item), tail));
    }
    if (tail instanceof LawSpecRuntime.Nothing<Chain<A>>) {
      throw new IllegalArgumentException("empty chain without Stop has no logical value");
    }
    return ((LawSpecRuntime.Just<Chain<A>>) tail).value();
  }

  public static CodecDomain.Positive to_positive(Positive value) {
    return new CodecDomain.Positive(((Positive.PositiveCase) value).value);
  }

  public static Positive from_positive(CodecDomain.Positive value) {
    return new Positive.PositiveCase(value.unpack());
  }
}
