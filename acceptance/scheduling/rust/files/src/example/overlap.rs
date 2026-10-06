// User-owned LawSpec adapter: nap notes when it starts and ends a sleep.
#![allow(unused_variables, unused_imports, non_snake_case)]
use crate::lawspec_runtime as ls;

fn note(event: &str, n: i32) {
    use std::io::Write;
    let Ok(path) = std::env::var("LAWSPEC_SCHEDULE_LOG") else { return };
    if path.is_empty() {
        return;
    }
    let millis = std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map(|d| d.as_secs_f64() * 1000.0).unwrap_or(0.0);
    if let Ok(mut file) = std::fs::OpenOptions::new().create(true).append(true).open(path) {
        // One write per line, so lines from threads do not mix.
        let _ = file.write_all(format!("{event} {n} {millis:.3}\n").as_bytes());
    }
}

// LawSpec: (Int32 -> Bool)
pub async fn nap(value0: i32) -> bool {
    note("start", value0);
    std::thread::sleep(std::time::Duration::from_millis(300));
    note("end", value0);
    true
}
