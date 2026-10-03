// Scaffolded by LawSpec. User-owned; never overwritten.
// A Duration is a std::time::Duration.
use std::time::Duration;

pub fn remaining(value0: Duration, value1: Duration) -> Duration {
    value0.saturating_sub(value1)
}
