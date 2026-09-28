import java.util.ArrayList;
import java.util.HashMap;
import java.util.List;
import lawspec.data.Choice;
import lawspec.data.Pair;
import lawspec.data.Tree;
import lawspec.runtime.LawSpecDataCodecs;
import lawspec.runtime.LawSpecDataSchema;
import lawspec.runtime.LawSpecRuntime;
import lawspec.runtime.LawSpecRuntime.Data;
import lawspec.runtime.LawSpecRuntime.Presence;
import lawspec.runtime.LawSpecRuntime.Value;
import lawspec.runtime.LawSpecSchema;
import lawspec.runtime.LawSpecSchema.Constructor;
import lawspec.runtime.LawSpecSchema.Definition;
import lawspec.runtime.LawSpecSchema.Field;
import lawspec.runtime.LawSpecSchema.Named;
import lawspec.runtime.LawSpecSchema.Parameter;

public final class DataSchemaCheck {
  private static void require(boolean condition) {
    if (!condition) throw new AssertionError();
  }

  private static void reject(Runnable action, String context) {
    try {
      action.run();
    } catch (IllegalArgumentException expected) {
      require(expected.getMessage().contains(context));
      return;
    }
    throw new AssertionError("accepted invalid value: " + context);
  }

  public static void main(String[] args) {
    int bits = Integer.parseInt(args[0]);
    var schema = LawSpecDataSchema.create();
    var tree = new Named("Tree", new Named("UInt64"));
    var maximum = LawSpecRuntime.integer("UInt64", "18446744073709551615");
    var leaf = schema.construct(tree, "ctor::Leaf", List.of(maximum), bits);
    var listType = new Named("List", tree);
    var source = new ArrayList<Value>(List.of(leaf));
    var branch =
        schema.construct(
            tree, "ctor::Branch", List.of(new Value(LawSpecSchema.key(listType), source)), bits);
    source.clear();
    require(((List<?>) ((Data) branch.data()).fields().get(0).data()).size() == 1);
    require(schema.equal(tree, branch, branch, bits));
    require(!schema.equal(tree, leaf, branch, bits));
    reject(() -> schema.construct(tree, "ctor::Pair", List.of(maximum), bits), "does not belong");
    reject(() -> schema.construct(tree, "ctor::Leaf", List.of(), bits), "arity");
    reject(
        () -> schema.construct(new Named("Empty", new Named("Bool")), "Fake", List.of(), bits),
        "does not belong");
    reject(
        () ->
            schema.construct(
                tree,
                "ctor::Leaf",
                List.of(LawSpecRuntime.integer("UInt64", "18446744073709551616")),
                bits),
        "ctor::Leaf.value");
    reject(
        () ->
            schema.construct(tree, "ctor::Leaf", List.of(LawSpecRuntime.rational("1", "2")), bits),
        "ctor::Leaf.value");
    var badLeaf =
        new Value(
            LawSpecSchema.key(tree),
            new Data("ctor::Leaf", List.of(LawSpecRuntime.integer("UInt64", "-1"))));
    reject(
        () ->
            schema.construct(
                tree,
                "ctor::Branch",
                List.of(new Value(LawSpecSchema.key(listType), List.of(badLeaf))),
                bits),
        "ctor::Branch.children: [0]: ctor::Leaf.value");
    var floatingTree = new Named("Tree", new Named("Float64"));
    var nan =
        schema.construct(
            floatingTree,
            "ctor::Leaf",
            List.of(LawSpecRuntime.floating("Float64", "7ff8000000000000")),
            bits);
    require(!schema.equal(floatingTree, nan, nan, bits));
    var positiveZero =
        schema.construct(
            floatingTree,
            "ctor::Leaf",
            List.of(LawSpecRuntime.floating("Float64", "0000000000000000")),
            bits);
    var negativeZero =
        schema.construct(
            floatingTree,
            "ctor::Leaf",
            List.of(LawSpecRuntime.floating("Float64", "8000000000000000")),
            bits);
    require(schema.equal(floatingTree, positiveZero, negativeZero, bits));
    var symbols = new HashMap<String, Object>();
    var symbolTree = new Named("Tree", new Named("Symbol"));
    var symbol1 =
        schema.construct(
            symbolTree, "ctor::Leaf", List.of(LawSpecRuntime.symbol("one", "same", symbols)), bits);
    var symbol2 =
        schema.construct(
            symbolTree, "ctor::Leaf", List.of(LawSpecRuntime.symbol("two", "same", symbols)), bits);
    require(schema.equal(symbolTree, symbol1, symbol1, bits));
    require(!schema.equal(symbolTree, symbol1, symbol2, bits));
    var optionalTree = new Named("Maybe", tree);
    var just = schema.construct(optionalTree, "Maybe::Just", List.of(branch), bits);
    require(schema.equal(optionalTree, just, just, bits));
    require(
        !schema.equal(
            optionalTree,
            just,
            schema.construct(optionalTree, "Maybe::Nothing", List.of(), bits),
            bits));
    var presence = new Named("Nullable", new Named("Optional", tree));
    var absent = new Value(LawSpecSchema.key(presence), new Presence(false, null));
    var innerAbsent =
        new Value(
            LawSpecSchema.key(presence),
            new Presence(
                true,
                new Value(
                    LawSpecSchema.key(new Named("Optional", tree)), new Presence(false, null))));
    require(!schema.equal(presence, absent, innerAbsent, bits));
    reject(
        () ->
            schema.validate(
                presence, new Value(LawSpecSchema.key(presence), new Presence(false, leaf)), bits),
        "absent payload");
    reject(
        () ->
            new LawSpecSchema(
                List.of(
                    new Definition(
                        "Bad",
                        0,
                        List.of(
                            new Constructor(
                                "Bad::Bad", List.of(new Field("value", new Parameter(0)))))))),
        "unbound");
    reject(
        () ->
            new LawSpecSchema(
                List.of(
                    new Definition(
                        "Bad",
                        0,
                        List.of(
                            new Constructor(
                                "Bad::Bad", List.of(new Field("value", new Named("Missing")))))))),
        "application");
    reject(() -> schema.validate(new Named("Tree"), leaf, bits), "application");
    var integerCodec = schema.scalar("Int32", bits, Integer.class);
    var treeCodec = LawSpecDataCodecs.treeCodec(schema, bits, integerCodec);
    var mutableChildren = new ArrayList<Tree<Integer>>();
    mutableChildren.add(new Tree.LeafCase<>(127));
    var nativeBranch = new Tree.BranchCase<Integer>(mutableChildren);
    var encodedBranch = treeCodec.encode(nativeBranch);
    mutableChildren.clear();
    var decodedBranch = (Tree.BranchCase<Integer>) treeCodec.decode(encodedBranch);
    require(decodedBranch.children.size() == 1);
    require(((Tree.LeafCase<Integer>) decodedBranch.children.get(0)).value == 127);
    decodedBranch.children.clear();
    require(((Tree.BranchCase<Integer>) treeCodec.decode(encodedBranch)).children.size() == 1);
    var wrongType =
        new Value(
            LawSpecSchema.key(treeCodec.type()),
            new Data("ctor::Leaf", List.of(LawSpecRuntime.bool(true))));
    reject(() -> treeCodec.decode(wrongType), "ctor::Leaf.value");
    var choiceCodec = LawSpecDataCodecs.choiceCodec(schema, bits, integerCodec);
    Choice<Integer> nativeChoice =
        new Choice.ChooseCase<>(
            new LawSpecRuntime.Right<>(
                new Pair.PairCase<>("text", new java.math.BigInteger("18446744073709551615"))));
    var encodedChoice = choiceCodec.encode(nativeChoice);
    require(
        schema.equal(
            choiceCodec.type(),
            encodedChoice,
            choiceCodec.encode(choiceCodec.decode(encodedChoice)),
            bits));
    var rawCodec =
        LawSpecDataCodecs.treeCodec(
            schema, bits, schema.scalar("CodeUnit16", bits, Character.class));
    var raw = rawCodec.decode(rawCodec.encode(new Tree.LeafCase<>('\uD800')));
    require(((Tree.LeafCase<Character>) raw).value == '\uD800');
    var optionalCodec = schema.maybe(treeCodec, bits);
    var optional = new LawSpecRuntime.Just<Tree<Integer>>(new Tree.LeafCase<>(-128));
    require(optionalCodec.decode(optionalCodec.encode(optional)) instanceof LawSpecRuntime.Just<?>);
    var bytesCodec = schema.scalar("Bytes", bits, byte[].class);
    var nativeBytes = new byte[] {0, (byte) 255};
    var encodedBytes = bytesCodec.encode(nativeBytes);
    nativeBytes[0] = 7;
    require(bytesCodec.decode(encodedBytes)[0] == 0);
    var productCodec = LawSpecDataCodecs.pairCodec(schema, bits, integerCodec);
    reject(
        () -> productCodec.encode(new Pair.PairCase<>(1, java.math.BigInteger.valueOf(-1))),
        "UInt64");
    System.out.println("Java generated schema validation and equality passed: " + bits);
  }
}
