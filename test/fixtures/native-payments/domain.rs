// Application-owned types: no dependency on generated lawspec_data types.
use crate::lawspec_runtime::Decimal;

#[derive(Clone, Debug)]
pub enum CurrencyCode {
    Dollars,
    Euros,
    Pounds,
}

#[derive(Clone, Debug)]
pub struct Price {
    pub major: Decimal,
    pub unit: CurrencyCode,
}

#[derive(Clone, Debug)]
pub enum PaymentStatus {
    Settled { price: Price },
    Rejected { explanation: String },
}

pub fn apply_fee(mut price: Price) -> Price {
    price.major = price
        .major
        .add(&Decimal::new(2.into(), (-1).into()))
        .unwrap();
    price
}

pub fn restore(payment: PaymentStatus) -> PaymentStatus {
    payment
}

pub fn store(payments: Vec<Option<PaymentStatus>>) -> Vec<Option<PaymentStatus>> {
    payments
}
