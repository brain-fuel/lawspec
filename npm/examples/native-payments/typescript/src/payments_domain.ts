// Application-owned domain types; no generated domain declarations.
import * as ls from './lawspec_runtime.js';

export class CurrencyCode {}
export class Dollars extends CurrencyCode {}
export class Euros extends CurrencyCode {}
export class Pounds extends CurrencyCode {}

export class Price {
  major: ls.Decimal;
  unit: CurrencyCode;
  constructor({unit, major}: {unit: CurrencyCode; major: ls.Decimal}) {
    this.unit = unit;
    this.major = major;
  }
}
export class PaymentStatus {}
export class Settled extends PaymentStatus {
  price: Price;
  constructor({price}: {price: Price}) {
    super();
    this.price = price;
  }
}
export class Rejected extends PaymentStatus {
  explanation: string;
  constructor({explanation}: {explanation: string}) {
    super();
    this.explanation = explanation;
  }
}
export function apply_fee(price: Price): Price {
  const major = ls.binary('+', price.major, new ls.Decimal(2n, -1n),
    'Decimal', 'Decimal') as ls.Decimal;
  return new Price({major, unit: price.unit});
}
export function restore<T>(payment: T): T {
  return payment;
}
export function store<T>(payments: T[]): T[] {
  return payments;
}
