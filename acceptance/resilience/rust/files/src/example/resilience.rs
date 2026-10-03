// Scaffolded by LawSpec. User-owned; never overwritten.
// The workflow runtime under test.
use crate::lawspec_runtime as ls;
use num_traits::ToPrimitive;

fn retry(strategy: &'static str, delay: i64, step: i64, factor: i64) -> ls::Retry {
    ls::Retry { strategy, delay, step, factor, cap: -1, attempts: 0, jitter: "none", when: None, decide: None }
}

fn int(value: &ls::BigInt) -> i64 {
    value.to_i64().expect("a small integer")
}

pub fn runtimeExponentialDelay(value0: ls::BigInt, value1: ls::BigInt, value2: ls::BigInt) -> ls::Integer {
    ls::Integer(ls::retry_delay(&retry("exponential", int(&value0), 0, int(&value1)), int(&value2)).into())
}

pub fn runtimeLinearDelay(value0: ls::BigInt, value1: ls::BigInt, value2: ls::BigInt) -> ls::Integer {
    ls::Integer(ls::retry_delay(&retry("linear", int(&value0), int(&value1), 0), int(&value2)).into())
}

pub fn runtimeFibonacciDelay(value0: ls::BigInt, value1: ls::BigInt) -> ls::Integer {
    ls::Integer(ls::retry_delay(&retry("fibonacci", int(&value0), 0, 0), int(&value1)).into())
}

pub fn splitMix(value0: u64, value1: i32) -> Vec<u64> {
    let mut random = ls::SplitMix64::new(value0);
    (0..value1).map(|_| random.next()).collect()
}

pub fn fullJitter(value0: u64, value1: ls::BigInt) -> ls::Integer {
    ls::Integer(ls::jittered("full", int(&value1), 0, 0, &mut ls::SplitMix64::new(value0)).into())
}

fn waits(attempts: i32, when: Option<fn(&mut ls::Context, ls::Value) -> ls::Result<bool>>) -> Vec<ls::Integer> {
    let ctx = &mut ls::Context::with_workflow(ls::WorkflowRuntime::new(Box::new(ls::VirtualClock::default()), 0));
    let policy = ls::StagePolicy {
        stage: "stage",
        retry: Some(ls::Retry { strategy: "exponential", delay: 100000, step: 0, factor: 2, cap: -1, attempts: attempts.into(), jitter: "none", when, decide: None }),
        timeout: -1,
        key: "stage",
        gates: vec![],
        cache: -1,
        wraps: false,
        compensate: None,
        hedge: None,
    };
    ls::run_stage(ctx, &policy, |_| Ok(ls::Value::Left(Box::new(ls::Value::Integer(0.into())))), ls::Value::Unit).expect("the stage runs");
    let runtime = ctx.workflow.as_ref().unwrap().lock().unwrap();
    runtime.trace.iter().filter(|event| event.kind == "sleep").map(|event| ls::Integer(event.number.into())).collect()
}

pub fn retriedWaits(value0: i32) -> Vec<ls::Integer> {
    waits(value0, None)
}

pub fn rejectedWaits(value0: i32) -> Vec<ls::Integer> {
    waits(value0, Some(|_: &mut ls::Context, _: ls::Value| -> ls::Result<bool> { Ok(false) }))
}

/// Calls the generated workflow at each time under one runtime.
pub fn limitedAt(value0: Vec<ls::BigInt>) -> Vec<bool> {
    let ctx = &mut ls::Context::with_workflow(ls::WorkflowRuntime::new(Box::new(ls::VirtualClock::default()), 0));
    value0
        .iter()
        .map(|time| {
            let runtime = ctx.workflow.clone().unwrap();
            runtime.lock().unwrap().clock = Box::new(ls::VirtualClock { time: int(time) });
            let result = crate::lawspec_definitions::example_limits::limited(ctx, crate::lawspec_data::Ticket { number: 0 });
            matches!(result, Ok(ls::Either::Right(_)))
        })
        .collect()
}

/// Books a ticket under a fresh runtime: the stages whose undos ran.
pub fn compensationsFor(value0: i64) -> Vec<String> {
    let ctx = &mut ls::Context::with_workflow(ls::WorkflowRuntime::new(Box::new(ls::VirtualClock::default()), 0));
    let _ = crate::lawspec_definitions::example_limits::book(ctx, crate::lawspec_data::Ticket { number: value0 });
    let runtime = ctx.workflow.as_ref().unwrap().lock().unwrap();
    runtime.trace.iter().filter(|event| event.kind == "compensate").map(|event| event.stage.clone()).collect()
}

/// Quotes a ticket under a runtime with the real clock: whether it timed out.
pub async fn quoteTimedOut(value0: i64) -> bool {
    let ctx = &mut ls::Context::with_workflow(ls::WorkflowRuntime::new(Box::new(ls::RealClock::default()), 0));
    let result = crate::lawspec_definitions::example_limits::quoted(ctx, crate::lawspec_data::Ticket { number: value0 });
    matches!(result, Ok(ls::Either::Left(crate::lawspec_data::QuotedError::QuotedTimedOut)))
}

/// Quotes a ticket under a runtime with the real clock: whether it succeeded
/// within 400ms, for ticket -2 through a hedged attempt.
pub async fn quoteHedged(value0: i64) -> bool {
    crate::example_limits::reset_quotes();
    let ctx = &mut ls::Context::with_workflow(ls::WorkflowRuntime::new(Box::new(ls::RealClock::default()), 0));
    let started = std::time::Instant::now();
    let result = crate::lawspec_definitions::example_limits::hedged(ctx, crate::lawspec_data::Ticket { number: value0 });
    let quick = started.elapsed() < std::time::Duration::from_millis(400);
    let hedged = ctx.workflow.as_ref().unwrap().lock().unwrap().trace.iter().any(|event| event.kind == "hedge");
    matches!(result, Ok(ls::Either::Right(_))) && quick && (value0 != -2 || hedged)
}
