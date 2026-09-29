import domain.CodecDomain;
import java.util.HashMap;
import java.util.List;
import lawspec.runtime.LawSpecDataSchema;
import lawspec.runtime.LawSpecNativeCodecs;
import lawspec.runtime.LawSpecRuntime;
import lawspec.runtime.LawSpecRuntime.Data;
import lawspec.runtime.LawSpecSchema.Named;

public final class JavaCodecBindingsCheck {
  public static void main(String[] args) {
    int bits = Integer.parseInt(args[0]);
    var schema = LawSpecDataSchema.create();
    var symbols = new HashMap<String, Object>();
    var child = LawSpecNativeCodecs.type0(
        schema, bits, symbols, schema.scalar("Int8", bits, Byte.class));
    var nested = LawSpecNativeCodecs.type0(schema, bits, symbols, child);
    var value = new CodecDomain.Parcel<>(new CodecDomain.Parcel<>((byte) 127));
    if (nested.decode(nested.encode(value)).unpack().unpack() != 127) {
      throw new AssertionError("nested private payload changed");
    }
    try {
      schema.construct(
          new Named("bound.codecs::type::Parcel", new Named("Int8")),
          "bound.codecs::type::Parcel::Parcel",
          List.of(LawSpecRuntime.integer("Int8", "128")), bits, symbols);
      throw new AssertionError("out-of-range payload unexpectedly accepted");
    } catch (IllegalArgumentException expected) {
      if (!expected.getMessage().contains("Int8")) throw expected;
    }
    System.out.println("Source-only Java codec nesting and checked ranges pass");
  }
}
