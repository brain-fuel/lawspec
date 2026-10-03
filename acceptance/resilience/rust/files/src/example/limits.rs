// Scaffolded by LawSpec. User-owned; never overwritten.
use crate::lawspec_runtime as ls;

pub fn admitTicket(value0: crate::lawspec_data::Ticket) -> ls::Either<String, crate::lawspec_data::Ticket> {
    ls::Either::Right(value0)
}

pub fn reserveSeat(value0: crate::lawspec_data::Ticket) -> ls::Either<String, crate::lawspec_data::Ticket> {
    ls::Either::Right(value0)
}

pub fn chargeCard(value0: crate::lawspec_data::Ticket) -> ls::Either<String, crate::lawspec_data::Ticket> {
    if value0.number < 0 {
        return ls::Either::Left("declined".to_string());
    }
    ls::Either::Right(value0)
}

pub fn releaseSeat(value0: crate::lawspec_data::Ticket) -> bool {
    true
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

/// Ticket -1's quote takes 600ms.
pub async fn fetchQuote(value0: crate::lawspec_data::Ticket) -> ls::Either<String, crate::lawspec_data::Ticket> {
    if value0.number == -1 {
        Sleep { until: std::time::Instant::now() + std::time::Duration::from_millis(600), started: false }.await;
    }
    ls::Either::Right(value0)
}

static QUOTES: std::sync::atomic::AtomicI64 = std::sync::atomic::AtomicI64::new(0);

pub fn reset_quotes() {
    QUOTES.store(0, std::sync::atomic::Ordering::SeqCst);
}

/// Ticket -2's first quote (and every other one after) stalls.
pub async fn hedgeQuote(value0: crate::lawspec_data::Ticket) -> ls::Either<String, crate::lawspec_data::Ticket> {
    if value0.number == -2 && QUOTES.fetch_add(1, std::sync::atomic::Ordering::SeqCst) % 2 == 0 {
        Sleep { until: std::time::Instant::now() + std::time::Duration::from_millis(600), started: false }.await;
    }
    ls::Either::Right(value0)
}
