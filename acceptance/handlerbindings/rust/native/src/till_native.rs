// Application code the till's bindings name: its own money type, a till
// that is the production handler, and payments that panic with its own
// errors.
use crate::lawspec_abilities::example_till::Drawer;

#[derive(Clone, Debug, PartialEq)]
pub struct Cash {
    pub cents: i64,
}

#[derive(Debug)]
pub struct CardDeclined;

pub struct BadAmount(pub String);

impl std::fmt::Debug for BadAmount {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(&self.0)
    }
}

/// A till that keeps what it takes, in the application's types.
#[derive(Default)]
pub struct NativeTill {
    taken: std::sync::Mutex<i64>,
}

impl NativeTill {
    pub fn take(&self, money: Cash) -> Cash {
        *self.taken.lock().unwrap() += money.cents;
        Cash { cents: money.cents }
    }

    pub fn opening(&self) -> Cash {
        Cash { cents: 0 }
    }
}

/// A bound adapter. It gets its drawer as the generated trait.
pub fn pay(drawer: &dyn Drawer, cents: i64) -> Cash {
    if cents < 0 {
        std::panic::panic_any(BadAmount("negative".to_string()));
    }
    if cents > 1000 {
        std::panic::panic_any(CardDeclined);
    }
    Cash { cents: drawer.take(crate::lawspec_data::Money { cents }).cents }
}
