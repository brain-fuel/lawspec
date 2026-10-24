// User-owned LawSpec adapter. ref:DEC-acceptance-with-mutants
namespace Example;

using System.Numerics;
using LawSpec.Data;

public static class Arithmetic
{
    private static long Length(Row row) => row is Row.Cell cell ? 1L + Length(cell.value.Tail) : 0L;

    public static Perfect Mirror(Perfect tree) => tree switch
    {
        Perfect.Node node => Perfect.NewNode(new LawSpec.Data.NodeDetails(Mirror(node.value.Right), Mirror(node.value.Left))),
        _ => tree,
    };

    public static BigInteger Area(Grid grid) => new BigInteger(Length(grid.Value.Rows) * Length(grid.Value.Columns));

    public static Halves Duplicate(Row row) => new Halves(new LawSpec.Data.HalvesDetails(row, row));

    public static Pairs CountPairs(Row row) => new Pairs(row);

    public static Rest DropFirst(Row row) => new Rest(row);
}
