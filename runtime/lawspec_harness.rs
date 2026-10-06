//! The harness plane at run time (see docs/reference/language/harness.md):
//! how a law's tests run, never what the law means. Generated tests call it
//! for strategies (drawn from a seed proptest chooses), adequacy (cover,
//! classify, label), run metadata (known failing, timeout, repeat, retry
//! flaky) and benchmarks.
//!
//! Statistics go to standard output, and, when LAWSPEC_STATS names a
//! directory, to one JSON file per test there, which lawspec test reads.
#![allow(dead_code)]
use crate::lawspec_runtime::{self as ls, Value};
use proptest::strategy::{Strategy, ValueTree};
use std::collections::BTreeMap;
use std::sync::Mutex;

fn quote(text: &str) -> String {
    let mut out = String::from("\"");
    for c in text.chars() {
        match c {
            '"' => out.push_str("\\\""),
            '\\' => out.push_str("\\\\"),
            c if (c as u32) < 0x20 => out.push_str(&format!("\\u{:04x}", c as u32)),
            c => out.push(c),
        }
    }
    out.push('"');
    out
}

pub fn record(name: &str, entry: &[(&str, String)]) {
    let Ok(directory) = std::env::var("LAWSPEC_STATS") else { return };
    if directory.is_empty() {
        return;
    }
    let _ = std::fs::create_dir_all(&directory);
    let safe: String = name.chars().map(|c| if c.is_ascii_alphanumeric() || c == '-' || c == '_' { c } else { '_' }).collect();
    let body = entry.iter().map(|(k, v)| format!("{}:{}", quote(k), v)).collect::<Vec<_>>().join(",");
    let _ = std::fs::write(format!("{directory}/{safe}.json"), format!("{{{body}}}"));
}

/// The draws of one strategy value: choices from a seed proptest chooses
/// (and shrinks toward zero), and default values sampled from proptest's
/// own strategies with that seed.
pub struct Draws {
    state: u64,
}

impl Draws {
    pub fn new(seed: u64) -> Draws {
        Draws { state: seed }
    }

    fn next(&mut self) -> u64 {
        self.state = self.state.wrapping_add(0x9E3779B97F4A7C15);
        let mut z = self.state;
        z = (z ^ (z >> 30)).wrapping_mul(0xBF58476D1CE4E5B9);
        z = (z ^ (z >> 27)).wrapping_mul(0x94D049BB133111EB);
        z ^ (z >> 31)
    }

    /// A choice among n.
    pub fn choose(&mut self, n: u64) -> u64 {
        self.next() % n
    }

    /// A value of the default strategy.
    pub fn any(&mut self, strategy: &proptest::strategy::BoxedStrategy<Value>) -> Value {
        let mut bytes = [0u8; 32];
        for chunk in bytes.chunks_mut(8) {
            chunk.copy_from_slice(&self.next().to_le_bytes());
        }
        let rng = proptest::test_runner::TestRng::from_seed(proptest::test_runner::RngAlgorithm::ChaCha, &bytes);
        let mut runner = proptest::test_runner::TestRunner::new_with_rng(proptest::test_runner::Config::default(), rng);
        strategy.new_tree(&mut runner).expect("the default strategy draws a value").current()
    }
}

/// A strategy's value, or a panic that names the harness's failure.
pub fn drawn(value: ls::Result<Value>) -> Value {
    value.unwrap_or_else(|error| panic!("{error}"))
}

pub fn outside(strategy: &str, name: &str, value: &Value) -> String {
    format!("the strategy {strategy} produced {value:?} for {name}, which is outside the input's refinement; a strategy may only produce values of its type")
}

pub fn discarded(strategy: &str, limit: usize) -> String {
    format!("the strategy {strategy} discarded more than {limit} values; draw closer to what `such that` keeps, or allow more discards")
}

#[derive(Default, Clone)]
struct Stats {
    cases: usize,
    cover: BTreeMap<String, usize>,
    classes: BTreeMap<String, usize>,
    labels: BTreeMap<String, usize>,
    best: Option<f64>,
}

static STATISTICS: Mutex<BTreeMap<String, Stats>> = Mutex::new(BTreeMap::new());

fn text(value: &Value) -> String {
    let rendered = format!("{value:?}");
    match rendered.strip_prefix("Text(\"").and_then(|r| r.strip_suffix("\")")) {
        Some(inner) => inner.to_string(),
        None => rendered.trim_matches('"').to_string(),
    }
}

/// What one generated case covers, classifies and labels.
pub fn observe(law: &str, covers: &[(&str, bool)], classes: &[(&str, bool)], labels: &[Value]) {
    let mut table = STATISTICS.lock().unwrap_or_else(|e| e.into_inner());
    let stats = table.entry(law.to_string()).or_default();
    stats.cases += 1;
    for (label, holds) in covers {
        if *holds {
            *stats.cover.entry(label.to_string()).or_default() += 1;
        }
    }
    for (label, holds) in classes {
        if *holds {
            *stats.classes.entry(label.to_string()).or_default() += 1;
        }
    }
    for value in labels {
        *stats.labels.entry(text(value)).or_default() += 1;
    }
}

/// target maximize: proptest has no targeted search, so the best score is
/// reported with the law's statistics.
pub fn target(score: &Value, law: &str) {
    let value: f64 = format!("{score:?}").trim_matches(|c: char| !(c.is_ascii_digit() || c == '-' || c == '.')).parse().unwrap_or(f64::NAN);
    let mut table = STATISTICS.lock().unwrap_or_else(|e| e.into_inner());
    let stats = table.entry(law.to_string()).or_default();
    stats.best = Some(stats.best.map_or(value, |b| b.max(value)));
}

fn adequacy(law: &str, covers: &[(u32, &str)]) -> (Vec<(&'static str, String)>, Vec<String>) {
    let stats = STATISTICS.lock().unwrap_or_else(|e| e.into_inner()).remove(law).unwrap_or_default();
    let n = stats.cases;
    let percent = |k: usize| if n == 0 { 0.0 } else { (10000.0 * k as f64 / n as f64).round() / 100.0 };
    let mut lines = vec![format!("{law}: {n} generated case(s)")];
    let mut results = Vec::new();
    let mut unmet = Vec::new();
    for (required, label) in covers {
        let observed = percent(*stats.cover.get(*label).unwrap_or(&0));
        let met = n > 0 && observed >= *required as f64;
        lines.push(format!("  cover {required}% {}: {observed}%{}", quote(label), if met { "" } else { " (not met)" }));
        results.push(format!("{{\"label\":{},\"required\":{required},\"observed\":{observed},\"met\":{met}}}", quote(label)));
        if !met {
            unmet.push(format!("{law}: cover {required}% {} was not met ({observed}% of {n} generated cases)", quote(label)));
        }
    }
    for (label, count) in &stats.classes {
        lines.push(format!("  {label}: {:.1}%", percent(*count)));
    }
    for (label, count) in &stats.labels {
        lines.push(format!("  label {label}: {:.1}%", percent(*count)));
    }
    if let Some(best) = stats.best {
        lines.push(format!("  best target score: {best}"));
    }
    println!("{}", lines.join("\n"));
    let table = |m: &BTreeMap<String, usize>| format!("{{{}}}", m.iter().map(|(k, v)| format!("{}:{v}", quote(k))).collect::<Vec<_>>().join(","));
    let report = vec![
        ("cases", n.to_string()),
        ("cover", format!("[{}]", results.join(","))),
        ("classes", table(&stats.classes)),
        ("labels", table(&stats.labels)),
    ];
    (report, unmet)
}

fn once(law: &str, timeout: u64, test: fn() -> ls::Result<()>) -> Result<(), (String, bool)> {
    let (sender, receiver) = std::sync::mpsc::channel();
    std::thread::spawn(move || {
        let outcome = std::panic::catch_unwind(test);
        let _ = sender.send(outcome);
    });
    let outcome = if timeout == 0 {
        receiver.recv().map_err(|e| (e.to_string(), true))?
    } else {
        match receiver.recv_timeout(std::time::Duration::from_millis(timeout)) {
            Ok(outcome) => outcome,
            Err(_) => return Err((format!("{law} took longer than its timeout of {timeout} ms"), true)),
        }
    };
    match outcome {
        Ok(Ok(())) => Ok(()),
        Ok(Err(error)) => Err((error, false)),
        Err(panic) => {
            let message = panic.downcast_ref::<String>().cloned()
                .or_else(|| panic.downcast_ref::<&str>().map(|s| s.to_string()))
                .unwrap_or_else(|| "the test panicked".to_string());
            let harness = message.contains("outside the input's refinement") || message.contains("discarded more than");
            Err((message, harness))
        }
    }
}

/// Run one law's test under its harness settings.
pub fn run(law: &str, name: &str, timeout: u64, repeat: u32, retries: u32, covers: &[(u32, &str)], observed: bool,
    test: fn() -> ls::Result<()>) -> ls::Result<()> {
    let mut attempts = 0;
    let mut flaky = false;
    let mut report = Vec::new();
    loop {
        attempts += 1;
        let mut failure = None;
        for _ in 0..repeat {
            STATISTICS.lock().unwrap_or_else(|e| e.into_inner()).remove(law);
            if let Err(error) = once(law, timeout, test) {
                failure = Some(error);
                break;
            }
            if observed {
                let (r, unmet) = adequacy(law, covers);
                report = r;
                if !unmet.is_empty() {
                    failure = Some((unmet.join("; "), true));
                    break;
                }
            }
        }
        match failure {
            None => break,
            Some((message, harness)) => {
                let message = if message.contains(law) { message } else { format!("{law}: {message}") };
                if harness || attempts > retries {
                    record(name, &[("law", quote(law)), ("test", quote(name)), ("outcome", quote("failed")), ("attempts", attempts.to_string())]);
                    return Err(message);
                }
                flaky = true;
            }
        }
    }
    let mut entry = vec![("law", quote(law)), ("test", quote(name)),
        ("outcome", quote(if flaky { "flaky" } else { "passed" })), ("attempts", attempts.to_string())];
    entry.extend(report);
    record(name, &entry);
    if flaky {
        println!("{law} is flaky: it failed, then passed on attempt {attempts}");
    }
    Ok(())
}

/// A known-failing law's test must fail. One that passes is reported: the
/// harness should no longer say it is known to fail.
pub fn known_failing(law: &str, name: &str, reason: &str, test: fn() -> ls::Result<()>) -> ls::Result<()> {
    match once(law, 0, test) {
        Err((message, _)) => {
            record(name, &[("law", quote(law)), ("test", quote(name)), ("outcome", quote("known-failing")), ("reason", quote(reason))]);
            println!("{law} is known to fail ({reason}): {}", message.lines().next().unwrap_or(""));
            Ok(())
        }
        Ok(()) => {
            record(name, &[("law", quote(law)), ("test", quote(name)), ("outcome", quote("known-failing-passed")), ("reason", quote(reason))]);
            Err(format!("{law} is marked known failing ({reason}), but it passes; remove `known failing` from its harness"))
        }
    }
}

/// Measured, never asserted: the mean and fastest time of body.
pub fn benchmark(name: &str, mut body: impl FnMut() -> ls::Result<()>) -> ls::Result<()> {
    let started = std::time::Instant::now();
    let mut times = Vec::new();
    while times.len() < 100000 && (started.elapsed().as_millis() < 200 || times.len() < 3) {
        let before = std::time::Instant::now();
        body()?;
        times.push(before.elapsed().as_nanos());
    }
    let mean = times.iter().sum::<u128>() / times.len() as u128;
    let fastest = *times.iter().min().unwrap_or(&0);
    println!("benchmark {name}: {} iteration(s), mean {:.2} us, fastest {:.2} us", times.len(), mean as f64 / 1000.0, fastest as f64 / 1000.0);
    record(&format!("benchmark {name}"), &[("benchmark", quote(name)), ("iterations", times.len().to_string()),
        ("mean_ns", mean.to_string()), ("min_ns", fastest.to_string())]);
    Ok(())
}

/// order random: libtest runs tests in name order, several at a time, and
/// its own shuffle is not stable. A unit with `order random` runs its law
/// tests one at a time instead, each waiting for its turn: among the tests
/// that have arrived and not run, the one the run's seed (LAWSPEC_SEED, or
/// the clock) ranks first runs next, once no other has arrived for a moment.
pub struct Turn(String);

struct Turns {
    running: bool,
    waiting: Vec<(u64, usize)>,
    arrived: std::time::Instant,
}

static TURNS: Mutex<BTreeMap<String, Turns>> = Mutex::new(BTreeMap::new());
static TURN_FREE: std::sync::Condvar = std::sync::Condvar::new();

fn turn_seed() -> u64 {
    static SEED: std::sync::OnceLock<u64> = std::sync::OnceLock::new();
    *SEED.get_or_init(|| {
        std::env::var("LAWSPEC_SEED").ok().and_then(|s| s.parse().ok()).unwrap_or_else(|| {
            std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map(|d| d.as_nanos() as u64).unwrap_or(0)
        })
    })
}

pub fn turn(unit: &str, index: usize) -> Turn {
    let rank = ls::SplitMix64::new(turn_seed() ^ (index as u64).wrapping_mul(0x9E3779B97F4A7C15)).next();
    let mut turns = TURNS.lock().unwrap_or_else(|e| e.into_inner());
    {
        let entry = turns.entry(unit.to_string()).or_insert_with(|| Turns { running: false, waiting: Vec::new(), arrived: std::time::Instant::now() });
        entry.waiting.push((rank, index));
        entry.arrived = std::time::Instant::now();
    }
    TURN_FREE.notify_all();
    loop {
        let entry = turns.get_mut(unit).expect("a unit's turns");
        let first = entry.waiting.iter().min().copied();
        if !entry.running && first == Some((rank, index)) && entry.arrived.elapsed() >= std::time::Duration::from_millis(20) {
            entry.waiting.retain(|w| *w != (rank, index));
            entry.running = true;
            return Turn(unit.to_string());
        }
        turns = TURN_FREE.wait_timeout(turns, std::time::Duration::from_millis(5)).unwrap_or_else(|e| e.into_inner()).0;
    }
}

impl Drop for Turn {
    fn drop(&mut self) {
        let mut turns = TURNS.lock().unwrap_or_else(|e| e.into_inner());
        if let Some(entry) = turns.get_mut(&self.0) {
            entry.running = false;
        }
        TURN_FREE.notify_all();
    }
}
