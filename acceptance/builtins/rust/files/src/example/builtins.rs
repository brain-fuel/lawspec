// Scaffolded by LawSpec. User-owned; never overwritten.
// Native code that gets the built-in abilities' handlers as arguments.
#![allow(unused_variables, unused_imports, non_snake_case)]
use crate::lawspec_runtime as ls;

// LawSpec: (Int32 -> lawspec.time::type::Duration)
pub fn elapsed(
    clock: &dyn crate::lawspec_abilities::lawspec_time::Clock,
    value0: i32,
) -> std::time::Duration {
    let start = clock.now().value;
    for _ in 0..value0 {
        clock.now();
    }
    std::time::Duration::from_micros((clock.now().value - start) as u64)
}

// LawSpec: (Int32 -> Bytes)
pub fn token(
    secureRandom: &dyn crate::lawspec_abilities::lawspec_randomness::SecureRandom,
    value0: i32,
) -> Vec<u8> {
    secureRandom.secureBytes(value0)
}

// LawSpec: (Int32 -> Bool)
pub fn listening(ports: &dyn crate::lawspec_abilities::lawspec_host::Ports, value0: i32) -> bool {
    std::net::TcpListener::bind(("127.0.0.1", ports.freePort() as u16)).is_ok()
}

// LawSpec: (Int32 -> Bool)
pub fn charge(log: &dyn crate::lawspec_abilities::lawspec_logging::Log, value0: i32) -> bool {
    if value0 % 2 == 0 {
        log.logMessage(crate::lawspec_data::LogLevel::Info, format!("charged {value0}"));
        true
    } else {
        false
    }
}
