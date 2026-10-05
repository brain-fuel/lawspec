// Scaffolded by LawSpec. User-owned; never overwritten.
use crate::lawspec_data::{Account, Signup, SignupError};
use crate::lawspec_runtime as ls;

pub fn audit(value0: Account) -> bool {
    true
}

pub fn waitlist(value0: SignupError) -> ls::Either<SignupError, Account> {
    if matches!(value0, SignupError::Unavailable) {
        return ls::Either::Right(Account { name: "waitlist".to_string(), age: 18, level: 0 });
    }
    ls::Either::Left(value0)
}

pub fn checkName(value0: Signup) -> ls::Either<SignupError, Signup> {
    if value0.name.is_empty() {
        return ls::Either::Left(SignupError::MissingName);
    }
    ls::Either::Right(value0)
}

pub fn checkAge(value0: Signup) -> ls::Either<String, Signup> {
    if value0.age < 18 {
        return ls::Either::Left("too young".to_string());
    }
    ls::Either::Right(value0)
}

pub fn openAccount(value0: Signup) -> ls::Either<SignupError, Account> {
    let Signup { name, age } = value0;
    if name == "taken" {
        return ls::Either::Left(SignupError::Unavailable);
    }
    ls::Either::Right(Account { name, age, level: 1 })
}

/// Completes at an instant, woken by a thread that sleeps until then.
struct Sleep {
    until: std::time::Instant,
    started: bool,
}

impl std::future::Future for Sleep {
    type Output = ();
    fn poll(mut self: std::pin::Pin<&mut Self>, context: &mut std::task::Context<'_>) -> std::task::Poll<()> {
        let now = std::time::Instant::now();
        if now >= self.until {
            return std::task::Poll::Ready(());
        }
        if !self.started {
            self.started = true;
            let (waker, wait) = (context.waker().clone(), self.until - now);
            std::thread::spawn(move || {
                std::thread::sleep(wait);
                waker.wake();
            });
        }
        std::task::Poll::Pending
    }
}

// Each check records when it fails, so approvalErrors can tell completion
// order from declaration order.
pub static FINISHED: std::sync::Mutex<Vec<String>> = std::sync::Mutex::new(Vec::new());

async fn check(value0: crate::lawspec_data::Order, milliseconds: u64, problem: &str) -> ls::Either<String, crate::lawspec_data::Order> {
    if value0.number == -1 {
        Sleep { until: std::time::Instant::now() + std::time::Duration::from_millis(milliseconds), started: false }.await;
    }
    if value0.number >= 0 {
        return ls::Either::Right(value0);
    }
    FINISHED.lock().unwrap().push(problem.to_string());
    ls::Either::Left(problem.to_string())
}

/// Order -1's stock check takes 400ms; a negative order has no stock.
pub async fn checkStock(value0: crate::lawspec_data::Order) -> ls::Either<String, crate::lawspec_data::Order> {
    check(value0, 400, "no stock").await
}

/// Order -1's credit check takes 250ms; a negative order has no credit.
pub async fn checkCredit(value0: crate::lawspec_data::Order) -> ls::Either<String, crate::lawspec_data::Order> {
    check(value0, 250, "no credit").await
}
