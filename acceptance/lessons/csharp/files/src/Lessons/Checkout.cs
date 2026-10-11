// User-owned LawSpec adapter.
namespace Lessons;

using LawSpec;
using LawSpec.Data;

public static class Checkout
{
    public static Either<OrderProblem, ValidOrder> Validate(RawOrder value0)
    {
        if (value0.Item.Length == 0) return Either<OrderProblem, ValidOrder>.NewLeft(OrderProblem.EmptyItem);
        if (value0.Quantity < 1 || value0.Quantity > 20) return Either<OrderProblem, ValidOrder>.NewLeft(OrderProblem.BadQuantity);
        return Either<OrderProblem, ValidOrder>.NewRight(new ValidOrder(value0.Item, new Quantity(value0.Quantity)));
    }

    public static Receipt Charge(ValidOrder value0) => new Receipt(value0.Item, value0.Quantity.Value * 250L);
}
