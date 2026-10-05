// Scaffolded by LawSpec. User-owned; never overwritten.
#![allow(unused_variables, unused_imports, non_snake_case)]
use crate::lawspec_runtime as ls;
use crate::lawspec_sessions::{hire, serve};
use ls::sessions::{par, spawn};

// A server: receives two numbers and sends their sum.
fn run_server(end: serve::first::Start) {
    let (a, end) = end.receive();
    let (b, end) = end.receive();
    let _done = end.send(i64::from(a) + i64::from(b));
}

// The client's side: sends both numbers and receives the sum.
fn ask(end: serve::second::Start, a: i32, b: i32) -> i64 {
    let end = end.send(a);
    let end = end.send(b);
    let (sum, _done) = end.receive();
    sum
}

// LawSpec: (Int32 -> (Int32 -> Integer))
pub fn add(value0: i32, value1: i32) -> ls::Integer {
    let (server, client) = serve::open();
    let process = spawn(move || run_server(server));
    let sum = ask(client, value0, value1);
    process.join();
    ls::Integer::from(sum)
}

// LawSpec: (Int32 -> (Int32 -> Integer))
pub fn addHired(value0: i32, value1: i32) -> ls::Integer {
    let (server, client) = serve::open();
    let (hirer, manager) = hire::open();
    let (sum, ()) = par(
        move || {
            let _done = hirer.send(server);
            ask(client, value0, value1)
        },
        // The manager is handed the server's end and serves it.
        move || {
            let (server, _done) = manager.receive();
            run_server(server)
        },
    );
    ls::Integer::from(sum)
}
