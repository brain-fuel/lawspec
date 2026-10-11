// User-owned LawSpec adapter. ref:DEC-acceptance-with-mutants
namespace Example;

using System.Numerics;
using LawSpec.Data;

public static class Arithmetic
{
    private static long Length(Row row) => row is Row.Cell cell ? 1L + Length(cell.tail) : 0L;

    public static Perfect Mirror(Perfect tree) => tree switch
    {
        Perfect.Node node => Perfect.NewNode(Mirror(node.right), Mirror(node.left)),
        _ => tree,
    };

    public static BigInteger Area(Grid grid) => new BigInteger(Length(grid.Rows) * Length(grid.Columns));

    public static Halves Duplicate(Row row) => new Halves(row, row);

    public static Pairs CountPairs(Row row) => new Pairs(row);

    public static Rest DropFirst(Row row) => new Rest(row);
}
