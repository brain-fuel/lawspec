// User-owned LawSpec adapter.
import * as data from '.././lawspec_data.js';

export function settlement(value0: data.ShopOrdersCurrency): data.ShopDomainCurrency {
  if (value0 instanceof data.ShopOrdersCurrencyUsd) return new data.ShopDomainCurrencyUsd();
  return new data.ShopDomainCurrencyEur();
}

export function lineTotal(value0: data.Line): data.Money {
  const total = value0.price.cents * BigInt(value0.quantity.value);
  return new data.MoneyMoney(value0.price.currency, total < 100000000n ? total : 100000000n);
}

export function cheaper(value0: bigint, value1: bigint): bigint {
  return value0 < value1 ? value0 : value1;
}

export function roundDown(value0: bigint): bigint {
  return value0 - value0 % 100n;
}
