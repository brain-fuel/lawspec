// Application-owned domain types; no generated domain declarations.
import * as ls from './lawspec_runtime.mjs';
export class CurrencyCode {
}
export class Dollars extends CurrencyCode {
}
export class Euros extends CurrencyCode {
}
export class Pounds extends CurrencyCode {
}
export class Price {
    major;
    unit;
    constructor({ unit, major }) {
        this.unit = unit;
        this.major = major;
    }
}
export class PaymentStatus {
}
export class Settled extends PaymentStatus {
    price;
    constructor({ price }) {
        super();
        this.price = price;
    }
}
export class Rejected extends PaymentStatus {
    explanation;
    constructor({ explanation }) {
        super();
        this.explanation = explanation;
    }
}
export function apply_fee(price) {
    const major = ls.binary('+', price.major, new ls.Decimal(2n, -1n), 'Decimal', 'Decimal');
    return new Price({ major, unit: price.unit });
}
export function restore(payment) {
    return payment;
}
export function store(payments) {
    return payments;
}
