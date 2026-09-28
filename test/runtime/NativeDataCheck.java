
import java.math.BigInteger;
import java.util.List;
import lawspec.data.*;
import lawspec.runtime.LawSpecRuntime;
public final class NativeDataCheck {
  static int size(Tree<Integer> tree) {
    return switch (tree) {
      case Tree.LeafCase<Integer> leaf -> 1;
      case Tree.BranchCase<Integer> branch ->
          1 + branch.children.stream().mapToInt(NativeDataCheck::size).sum();
    };
  }
  public static void main(String[] args) {
    Tree<Integer> tree = new Tree.BranchCase<>(List.of(
        new Tree.LeafCase<>(127), new Tree.BranchCase<>(List.of())));
    if (size(tree) != 3) throw new AssertionError("recursive type");
    var maximum = new BigInteger("18446744073709551615");
    Pair<String> pair = new Pair.PairCase<>("payload", maximum);
    Choice<Integer> choice = new Choice.ChooseCase<>(new LawSpecRuntime.Right<>(pair));
    var value = ((Choice.ChooseCase<Integer>) choice).value;
    if (!(value instanceof LawSpecRuntime.Right<?, ?> right)
        || !(right.value() instanceof Pair.PairCase<?> fields)
        || !fields.first.equals("payload") || !fields.second.equals(maximum)) {
      throw new AssertionError("nested generic payload");
    }
    System.out.println("native generic products, sums, recursive matches passed");
  }
}
