// 0.9 baseline: these conversions are hand-written. 0.10 must generate them.
#![allow(non_snake_case)]
#[path = "../domain.rs"]
mod domain;
use crate::lawspec_data::{Currency, Money, Payment};
use domain::{CurrencyCode, PaymentStatus, Price};

impl From<Currency> for CurrencyCode {
    fn from(value: Currency) -> Self {
        match value {
            Currency::USD => Self::Dollars,
            Currency::EUR => Self::Euros,
            Currency::GBP => Self::Pounds,
        }
    }
}

impl From<CurrencyCode> for Currency {
    fn from(value: CurrencyCode) -> Self {
        match value {
            CurrencyCode::Dollars => Self::USD,
            CurrencyCode::Euros => Self::EUR,
            CurrencyCode::Pounds => Self::GBP,
        }
    }
}

impl From<Money> for Price {
    fn from(value: Money) -> Self {
        let Money::Money { amount, currency } = value;
        Self {
            major: amount,
            unit: currency.into(),
        }
    }
}

impl From<Price> for Money {
    fn from(value: Price) -> Self {
        Self::Money {
            amount: value.major,
            currency: value.unit.into(),
        }
    }
}

impl From<Payment> for PaymentStatus {
    fn from(value: Payment) -> Self {
        match value {
            Payment::Paid { value } => Self::Settled {
                price: value.into(),
            },
            Payment::Declined { reason } => Self::Rejected {
                explanation: reason,
            },
        }
    }
}

impl From<PaymentStatus> for Payment {
    fn from(value: PaymentStatus) -> Self {
        match value {
            PaymentStatus::Settled { price } => Self::Paid {
                value: price.into(),
            },
            PaymentStatus::Rejected { explanation } => Self::Declined {
                reason: explanation,
            },
        }
    }
}

pub fn addFee(value: Money) -> Money {
    domain::apply_fee(value.into()).into()
}

pub fn roundTrip(value: Payment) -> Payment {
    domain::restore(value.into()).into()
}

pub fn archive(values: Vec<Option<Payment>>) -> Vec<Option<Payment>> {
    domain::store(values.into_iter().map(|v| v.map(Into::into)).collect())
        .into_iter()
        .map(|v| v.map(Into::into))
        .collect()
}
