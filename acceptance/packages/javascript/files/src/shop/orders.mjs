// User-owned LawSpec adapter.
import * as data from '.././lawspec_data.mjs';

export function settlement(value0) {
  if (value0 instanceof data.ShopOrdersCurrencyUsd) return new data.ShopDomainCurrencyUsd();
  return new data.ShopDomainCurrencyEur();
}

export function lineTotal(value0) {
  const total = value0.price.cents * BigInt(value0.quantity.value);
  return new data.Money(value0.price.currency, total < 100000000n ? total : 100000000n);
}

export function cheaper(value0, value1) {
  return value0 < value1 ? value0 : value1;
}

export function roundDown(value0) {
  return value0 - value0 % 100n;
}

// Version 2 of shop.tax: no tax on nothing, the high band from 100.00.
export function classify(value0) {
  if (value0 <= 0n) return new data.ShopTaxV200RatesBandZero();
  if (value0 < 10000n) return new data.ShopTaxV200RatesBandLow();
  return new data.ShopTaxV200RatesBandHigh();
}
