// Native adapters and mutants for examples/specs/domain_modeling.lawspec.
// Mutants break the wrapper invariant (validation admits quantity 0), the
// workflow's railway composition (a validation failure is replaced), and a
// NonEmptyList operation (the last element instead of the first).

const python = `# User-owned LawSpec adapter.
import lawspec_data as data
import lawspec_schema as _schema


def firstLine(value0):
    return value0.value[0]


def validateOrder(value0):
    if len(value0.id) == 0:
        return _schema.Left(data.OrderErrorInvalidOrderId())
    if not 1 <= value0.quantity <= 1000:
        return _schema.Left(data.OrderErrorInvalidQuantity())
    return _schema.Right(data.ValidatedOrderValidatedOrder(
        data.OrderIdOrderId(value0.id),
        data.UnitQuantityUnitQuantity(value0.quantity)))


def priceOrder(value0):
    total = value0.quantity.value * 25
    if total > 20000:
        return _schema.Left(data.OrderErrorPriceTooHigh())
    return _schema.Right(data.PricedOrderPricedOrder(value0.id, value0.quantity, total))


def placeOrder(value0):
    validated = validateOrder(value0)
    if isinstance(validated, _schema.Left):
        return validated
    return priceOrder(validated.value)
`;

const web = (typed) => {
  const t = (annotation) => (typed ? annotation : '');
  return `// User-owned LawSpec adapter.
import * as data from '.././lawspec_data.${typed ? 'js' : 'mjs'}';

export function firstLine(value0${t(': data.NonEmptyList<number>')})${t(': number')} {
  return value0.value[0];
}

export function validateOrder(value0${t(': data.UnvalidatedOrder')})${t(': data.Either<data.OrderError, data.ValidatedOrder>')} {
  if (value0.id.length === 0) return new data.Left(new data.OrderErrorInvalidOrderId());
  if (!(value0.quantity >= 1 && value0.quantity <= 1000)) return new data.Left(new data.OrderErrorInvalidQuantity());
  return new data.Right(new data.ValidatedOrderValidatedOrder(
      new data.OrderIdOrderId(value0.id), new data.UnitQuantityUnitQuantity(value0.quantity)));
}

export function priceOrder(value0${t(': data.ValidatedOrder')})${t(': data.Either<data.OrderError, data.PricedOrder>')} {
  const total = BigInt(value0.quantity.value) * 25n;
  if (total > 20000n) return new data.Left(new data.OrderErrorPriceTooHigh());
  return new data.Right(new data.PricedOrderPricedOrder(value0.id, value0.quantity, total));
}

export function placeOrder(value0${t(': data.UnvalidatedOrder')})${t(': data.Either<data.OrderError, data.PricedOrder>')} {
  const validated = validateOrder(value0);
  if (validated instanceof data.Left) return validated${t(' as data.Either<data.OrderError, data.PricedOrder>')};
  return priceOrder(validated.value);
}
`;
};

const java = `// User-owned LawSpec adapter.
package example;

import lawspec.data.NonEmptyList;
import lawspec.data.OrderError;
import lawspec.data.OrderId;
import lawspec.data.PricedOrder;
import lawspec.data.UnitQuantity;
import lawspec.data.UnvalidatedOrder;
import lawspec.data.ValidatedOrder;
import lawspec.runtime.LawSpecRuntime;

public final class Ordering {
  public static int firstLine(NonEmptyList<Integer> value0) {
    return ((NonEmptyList.NonEmptyListCase<Integer>) value0).value.get(0);
  }

  public static LawSpecRuntime.Either<OrderError, ValidatedOrder> validateOrder(
      UnvalidatedOrder value0) {
    var input = (UnvalidatedOrder.UnvalidatedOrderCase) value0;
    if (input.id.isEmpty()) return new LawSpecRuntime.Left<>(new OrderError.InvalidOrderIdCase());
    if (!(input.quantity >= 1 && input.quantity <= 1000)) {
      return new LawSpecRuntime.Left<>(new OrderError.InvalidQuantityCase());
    }
    return new LawSpecRuntime.Right<>(new ValidatedOrder.ValidatedOrderCase(
        new OrderId.OrderIdCase(input.id), new UnitQuantity.UnitQuantityCase(input.quantity)));
  }

  public static LawSpecRuntime.Either<OrderError, PricedOrder> priceOrder(ValidatedOrder value0) {
    var order = (ValidatedOrder.ValidatedOrderCase) value0;
    long total = (long) ((UnitQuantity.UnitQuantityCase) order.quantity).value * 25;
    if (total > 20000) return new LawSpecRuntime.Left<>(new OrderError.PriceTooHighCase());
    return new LawSpecRuntime.Right<>(new PricedOrder.PricedOrderCase(order.id, order.quantity, total));
  }

  public static LawSpecRuntime.Either<OrderError, PricedOrder> placeOrder(UnvalidatedOrder value0) {
    var validated = validateOrder(value0);
    if (validated instanceof LawSpecRuntime.Left<OrderError, ValidatedOrder> failure) {
      return new LawSpecRuntime.Left<>(failure.value());
    }
    return priceOrder(((LawSpecRuntime.Right<OrderError, ValidatedOrder>) validated).value());
  }
}
`;

const kotlin = `// User-owned LawSpec adapter.
package example

import lawspec.data.NonEmptyList
import lawspec.data.OrderError
import lawspec.data.OrderId
import lawspec.data.PricedOrder
import lawspec.data.UnitQuantity
import lawspec.data.UnvalidatedOrder
import lawspec.data.ValidatedOrder
import lawspec.runtime.LawSpecRuntime

object Ordering {
    fun firstLine(value0: NonEmptyList<Int>): Int = (value0 as NonEmptyList.NonEmptyListCase).value[0]

    fun validateOrder(value0: UnvalidatedOrder): LawSpecRuntime.Either<OrderError, ValidatedOrder> {
        val input = value0 as UnvalidatedOrder.UnvalidatedOrderCase
        if (input.id.isEmpty()) return LawSpecRuntime.Left(OrderError.InvalidOrderIdCase())
        if (input.quantity !in 1..1000) return LawSpecRuntime.Left(OrderError.InvalidQuantityCase())
        return LawSpecRuntime.Right(
            ValidatedOrder.ValidatedOrderCase(OrderId.OrderIdCase(input.id), UnitQuantity.UnitQuantityCase(input.quantity)),
        )
    }

    fun priceOrder(value0: ValidatedOrder): LawSpecRuntime.Either<OrderError, PricedOrder> {
        val order = value0 as ValidatedOrder.ValidatedOrderCase
        val total = (order.quantity as UnitQuantity.UnitQuantityCase).value.toLong() * 25
        if (total > 20000) return LawSpecRuntime.Left(OrderError.PriceTooHighCase())
        return LawSpecRuntime.Right(PricedOrder.PricedOrderCase(order.id, order.quantity, total))
    }

    fun placeOrder(value0: UnvalidatedOrder): LawSpecRuntime.Either<OrderError, PricedOrder> {
        val validated = validateOrder(value0)
        if (validated is LawSpecRuntime.Left) return LawSpecRuntime.Left(validated.value())
        return priceOrder((validated as LawSpecRuntime.Right).value())
    }
}
`;

const go = `// User-owned LawSpec adapter.
package ordering

// FirstLine returns the first element of a non-empty list.
func FirstLine(value0 NonEmptyList[int32]) int32 {
	return value0.(NonEmptyListNonEmptyList[int32]).Value[0]
}

// ValidateOrder checks the raw order and wraps its values.
func ValidateOrder(value0 UnvalidatedOrder) LawSpecEither[OrderError, ValidatedOrder] {
	input := value0.(UnvalidatedOrderUnvalidatedOrder)
	if len(input.Id) == 0 {
		return LawSpecLeft[OrderError, ValidatedOrder](OrderErrorInvalidOrderId{})
	}
	if !(input.Quantity >= 1 && input.Quantity <= 1000) {
		return LawSpecLeft[OrderError, ValidatedOrder](OrderErrorInvalidQuantity{})
	}
	return LawSpecRight[OrderError, ValidatedOrder](ValidatedOrderValidatedOrder{
		Id: OrderIdOrderId{Value: input.Id}, Quantity: UnitQuantityUnitQuantity{Value: input.Quantity}})
}

// PriceOrder prices a validated order.
func PriceOrder(value0 ValidatedOrder) LawSpecEither[OrderError, PricedOrder] {
	order := value0.(ValidatedOrderValidatedOrder)
	total := int64(order.Quantity.(UnitQuantityUnitQuantity).Value) * 25
	if total > 20000 {
		return LawSpecLeft[OrderError, PricedOrder](OrderErrorPriceTooHigh{})
	}
	return LawSpecRight[OrderError, PricedOrder](PricedOrderPricedOrder{Id: order.Id, Quantity: order.Quantity, Total: total})
}

// PlaceOrder validates and then prices an order.
func PlaceOrder(value0 UnvalidatedOrder) LawSpecEither[OrderError, PricedOrder] {
	validated := ValidateOrder(value0)
	if failure, ok := validated.Left(); ok {
		return LawSpecLeft[OrderError, PricedOrder](failure)
	}
	order, _ := validated.Right()
	return PriceOrder(order)
}
`;

const haskell = `-- User-owned LawSpec adapter.
module Example.Ordering (firstLine, validateOrder, priceOrder, placeOrder) where

import qualified Data.Int as I
import qualified Data.Text as T
import qualified LawSpecData as Data

firstLine :: Data.NonEmptyList I.Int32 -> I.Int32
firstLine (Data.NonEmptyListNonEmptyList values) = head values

validateOrder :: Data.UnvalidatedOrder -> Either Data.OrderError Data.ValidatedOrder
validateOrder (Data.UnvalidatedOrderUnvalidatedOrder orderId quantity)
  | T.null orderId = Left Data.OrderErrorInvalidOrderId
  | quantity < 1 || quantity > 1000 = Left Data.OrderErrorInvalidQuantity
  | otherwise = Right (Data.ValidatedOrderValidatedOrder
      (Data.OrderIdOrderId orderId) (Data.UnitQuantityUnitQuantity quantity))

priceOrder :: Data.ValidatedOrder -> Either Data.OrderError Data.PricedOrder
priceOrder (Data.ValidatedOrderValidatedOrder orderId quantity@(Data.UnitQuantityUnitQuantity count))
  | total > 20000 = Left Data.OrderErrorPriceTooHigh
  | otherwise = Right (Data.PricedOrderPricedOrder orderId quantity total)
  where total = fromIntegral count * 25 :: I.Int64

placeOrder :: Data.UnvalidatedOrder -> Either Data.OrderError Data.PricedOrder
placeOrder input = case validateOrder input of
  Left failure -> Left failure
  Right order -> priceOrder order
`;

const rust = `// Scaffolded by LawSpec. User-owned; never overwritten.
use crate::lawspec_data::{NonEmptyList, OrderError, OrderId, PricedOrder, UnitQuantity, UnvalidatedOrder, ValidatedOrder};
use crate::lawspec_runtime as ls;

pub fn firstLine(value0: NonEmptyList<i32>) -> i32 {
    let NonEmptyList::NonEmptyList { value } = value0;
    value[0]
}

pub fn validateOrder(value0: UnvalidatedOrder) -> ls::Either<OrderError, ValidatedOrder> {
    let UnvalidatedOrder::UnvalidatedOrder { id, quantity } = value0;
    if id.is_empty() {
        return ls::Either::Left(OrderError::InvalidOrderId);
    }
    if !(quantity >= 1 && quantity <= 1000) {
        return ls::Either::Left(OrderError::InvalidQuantity);
    }
    ls::Either::Right(ValidatedOrder::ValidatedOrder {
        id: OrderId::OrderId { value: id },
        quantity: UnitQuantity::UnitQuantity { value: quantity },
    })
}

pub fn priceOrder(value0: ValidatedOrder) -> ls::Either<OrderError, PricedOrder> {
    let ValidatedOrder::ValidatedOrder { id, quantity } = value0;
    let UnitQuantity::UnitQuantity { value: count } = quantity.clone();
    let total = i64::from(count) * 25;
    if total > 20000 {
        return ls::Either::Left(OrderError::PriceTooHigh);
    }
    ls::Either::Right(PricedOrder::PricedOrder { id, quantity, total })
}

pub fn placeOrder(value0: UnvalidatedOrder) -> ls::Either<OrderError, PricedOrder> {
    match validateOrder(value0) {
        ls::Either::Left(failure) => ls::Either::Left(failure),
        ls::Either::Right(order) => priceOrder(order),
    }
}
`;

const adapters = {python, javascript: web(false), typescript: web(true), java, kotlin, go, haskell, rust};

const mutations = {
  python: [
    ['invariant', 'if not 1 <= value0.quantity <= 1000:', 'if not 0 <= value0.quantity <= 1000:'],
    ['railway', '        return validated\n', '        return _schema.Left(data.OrderErrorPriceTooHigh())\n'],
    ['first', 'return value0.value[0]', 'return value0.value[-1]'],
  ],
  web: [
    ['invariant', 'value0.quantity >= 1 &&', 'value0.quantity >= 0 &&'],
    ['railway', 'if (validated instanceof data.Left) return validated', 'if (validated instanceof data.Left) return new data.Left(new data.OrderErrorPriceTooHigh())'],
    ['first', 'return value0.value[0];', 'return value0.value[value0.value.length - 1];'],
  ],
  java: [
    ['invariant', 'input.quantity >= 1 &&', 'input.quantity >= 0 &&'],
    ['railway', 'return new LawSpecRuntime.Left<>(failure.value());', 'return new LawSpecRuntime.Left<>(new OrderError.PriceTooHighCase());'],
    ['first', '.value.get(0);', '.value.get(((NonEmptyList.NonEmptyListCase<Integer>) value0).value.size() - 1);'],
  ],
  kotlin: [
    ['invariant', 'input.quantity !in 1..1000', 'input.quantity !in 0..1000'],
    ['railway', 'return LawSpecRuntime.Left(validated.value())', 'return LawSpecRuntime.Left(OrderError.PriceTooHighCase())'],
    ['first', '.value[0]', '.value.last()'],
  ],
  go: [
    ['invariant', 'input.Quantity >= 1 &&', 'input.Quantity >= 0 &&'],
    ['railway', 'return LawSpecLeft[OrderError, PricedOrder](failure)', '_ = failure\n\t\treturn LawSpecLeft[OrderError, PricedOrder](OrderErrorPriceTooHigh{})'],
    ['first', '.Value[0]', '.Value[len(value0.(NonEmptyListNonEmptyList[int32]).Value)-1]'],
  ],
  haskell: [
    ['invariant', 'quantity < 1 || quantity > 1000', 'quantity < 0 || quantity > 1000'],
    ['railway', 'Left failure -> Left failure', 'Left _ -> Left Data.OrderErrorPriceTooHigh'],
    ['first', '= head values', '= last values'],
  ],
  rust: [
    ['invariant', '!(quantity >= 1 &&', '!(quantity >= 0 &&'],
    ['railway', 'ls::Either::Left(failure) => ls::Either::Left(failure),', 'ls::Either::Left(_) => ls::Either::Left(OrderError::PriceTooHigh),'],
    ['first', 'value[0]', 'value[value.len() - 1]'],
  ],
};

export function domainAdapter(target) {
  return adapters[target];
}

export function domainMutants(target) {
  const correct = adapters[target];
  const list = mutations[['javascript', 'typescript'].includes(target) ? 'web' : target];
  return list.map(([name, before, after]) => {
    if (!correct.includes(before)) throw new Error(`${target}: missing mutant marker for ${name}`);
    return {name, content: correct.replace(before, after)};
  });
}
