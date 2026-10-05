// User-owned LawSpec adapter: the approve workflow under the real clock.
use crate::lawspec_data::{ApproveError, Order};
use crate::lawspec_runtime as ls;

/// Approves an order: whether it took less than 550ms.
pub async fn approvedQuickly(value0: i64) -> bool {
    let ctx = &mut ls::Context::with_workflow(ls::WorkflowRuntime::new(Box::new(ls::RealClock::default()), 0));
    let started = std::time::Instant::now();
    let _ = crate::lawspec_definitions::example_workflows::approve(ctx, Order { number: value0 });
    started.elapsed() < std::time::Duration::from_millis(550)
}

/// Approves an order: the messages of its failures, as reported.
pub async fn approvalErrors(value0: i64) -> Vec<String> {
    crate::example_workflows::FINISHED.lock().unwrap().clear();
    let ctx = &mut ls::Context::with_workflow(ls::WorkflowRuntime::new(Box::new(ls::RealClock::default()), 0));
    let result = crate::lawspec_definitions::example_workflows::approve(ctx, Order { number: value0 });
    let mut messages = Vec::new();
    if let Ok(ls::Either::Left(ApproveError::ApproveFailures { error: failures })) = result {
        for failure in failures {
            match failure {
                ApproveError::ApproveCheckStockFailed { error } => messages.push(error),
                ApproveError::ApproveCheckCreditFailed { error } => messages.push(error),
                _ => {}
            }
        }
    }
    messages
}
