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
    return new CodecDomain.Parcel<>(convert.apply(value.item()));
  }

  public static <A, B> Parcel<A> from_parcel(CodecDomain.Parcel<B> value, Function<B, A> convert) {
    return new Parcel<>(convert.apply(value.unpack()));
  }

  public static <A, B> CodecDomain.FlatChain<B> to_chain(Chain<A> value, Function<A, B> convert) {
    var items = new ArrayList<B>();
    while (value instanceof Chain.More<A>(var item, var tail)) {
      items.add(convert.apply(item));
      if (tail instanceof LawSpecRuntime.Just<Chain<A>> next) value = next.value();
      else return new CodecDomain.FlatChain<>(items, false);
    }
    return new CodecDomain.FlatChain<>(items, true);
  }

  public static <A, B> Chain<A> from_chain(CodecDomain.FlatChain<B> value, Function<B, A> convert) {
    LawSpecRuntime.Maybe<Chain<A>> tail = value.ended()
        ? new LawSpecRuntime.Just<>(new Chain.Stop<>()) : new LawSpecRuntime.Nothing<>();
    for (var item : value.items().reversed()) {
      tail = new LawSpecRuntime.Just<>(new Chain.More<>(convert.apply(item), tail));
    }
    if (tail instanceof LawSpecRuntime.Just<Chain<A>> chain) return chain.value();
    throw new IllegalArgumentException("empty chain without Stop has no logical value");
  }

  public static CodecDomain.Positive to_positive(Positive value) {
    return new CodecDomain.Positive(value.value());
  }

  public static Positive from_positive(CodecDomain.Positive value) {
    return new Positive(value.unpack());
  }
}
