// User-owned LawSpec adapter. ref:DEC-acceptance-with-mutants
namespace Example;

using Microsoft.FSharp.Collections;
using LawSpec;
using LawSpec.Data;

public static class Ordering
{
    public static int FirstLine(NonEmptyList<int> lines) => ListModule.Head(lines.Value);

    public static Either<OrderError, ValidatedOrder> ValidateOrder(UnvalidatedOrder order)
    {
        if (order.Id == "") return Either<OrderError, ValidatedOrder>.NewLeft(OrderError.InvalidOrderId);
        if (order.Quantity < 1 || order.Quantity > 1000) return Either<OrderError, ValidatedOrder>.NewLeft(OrderError.InvalidQuantity);
        return Either<OrderError, ValidatedOrder>.NewRight(new ValidatedOrder(new OrderId(order.Id), new UnitQuantity(order.Quantity)));
    }

    public static Either<OrderError, PricedOrder> PriceOrder(ValidatedOrder order)
    {
        long total = order.Quantity.Value * 25L;
        return total > 20000L
            ? Either<OrderError, PricedOrder>.NewLeft(OrderError.PriceTooHigh)
            : Either<OrderError, PricedOrder>.NewRight(new PricedOrder(order.Id, order.Quantity, total));
    }
}
