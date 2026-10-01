// Scaffolded by LawSpec. User-owned; never overwritten.
use crate::lawspec_data::{NonEmptyList, OrderError, OrderId, PricedOrder, UnitQuantity, UnvalidatedOrder, ValidatedOrder};
use crate::lawspec_runtime as ls;

pub fn firstLine(value0: NonEmptyList<i32>) -> i32 {
    let NonEmptyList { value } = value0;
    value[0]
}

pub fn validateOrder(value0: UnvalidatedOrder) -> ls::Either<OrderError, ValidatedOrder> {
    let UnvalidatedOrder { id, quantity } = value0;
    if id.is_empty() {
        return ls::Either::Left(OrderError::InvalidOrderId);
    }
    if !(quantity >= 1 && quantity <= 1000) {
        return ls::Either::Left(OrderError::InvalidQuantity);
    }
    ls::Either::Right(ValidatedOrder {
        id: OrderId { value: id },
        quantity: UnitQuantity { value: quantity },
    })
}

pub fn priceOrder(value0: ValidatedOrder) -> ls::Either<OrderError, PricedOrder> {
    let ValidatedOrder { id, quantity } = value0;
    let UnitQuantity { value: count } = quantity.clone();
    let total = i64::from(count) * 25;
    if total > 20000 {
        return ls::Either::Left(OrderError::PriceTooHigh);
    }
    ls::Either::Right(PricedOrder { id, quantity, total })
}

pub fn placeOrder(value0: UnvalidatedOrder) -> ls::Either<OrderError, PricedOrder> {
    match validateOrder(value0) {
        ls::Either::Left(failure) => ls::Either::Left(failure),
        ls::Either::Right(order) => priceOrder(order),
    }
}
