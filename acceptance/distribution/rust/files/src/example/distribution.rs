// Scaffolded by LawSpec. User-owned; never overwritten.
#![allow(unused_variables, non_snake_case)]
use crate::lawspec_data::{Pair, Tally};
use crate::lawspec_runtime as ls;
use std::time::Duration;

// The wire encoding, and nodes talking over in-memory, TCP and HTTP
// transports.
pub fn encoded(value0: String, value1: u64, value2: i32, value3: i32) -> Vec<String> {
    ls::net::wire_encoded(&value0, value1, i64::from(value2), i64::from(value3))
}

pub fn roundTrips(value0: String, value1: u64, value2: i32, value3: i32) -> bool {
    ls::net::wire_round_trips(&value0, value1, i64::from(value2), i64::from(value3))
}

pub async fn remoteShifted(value0: i32) -> i64 {
    let network = ls::net::MemoryNetwork::new(value0 as u64 & 0xFFFF, 0.2, 0.2, Duration::ZERO);
    let here = ls::net::Node::new(network.transport("here"));
    let there = ls::net::Node::new(network.transport("there"));
    crate::lawspec_remote::serve(&there).unwrap();
    let result = crate::lawspec_remote::evaluate(
        &here,
        &there.address(),
        "example.distribution::shifted",
        &[ls::IntoValue::into_value(value0)],
    )
    .unwrap();
    here.close();
    there.close();
    ls::FromValue::from_value(result).unwrap()
}

pub fn openTally(value0: ()) -> Tally {
    Tally { count: 0 }
}

pub fn add(value0: Tally, value1: u8) -> Pair<i64, Tally> {
    let after = value0.count + i64::from(value1);
    Pair { first: after, second: Tally { count: after } }
}

pub async fn remoteAdds(value0: u8) -> i64 {
    use crate::lawspec_actors::TallyActor;
    let server = ls::net::Node::new(ls::net::TcpTransport::local().unwrap());
    let client = ls::net::Node::new(ls::net::TcpTransport::local().unwrap());
    let address = TallyActor::start().serve(&server, "tally").unwrap();
    let tally = TallyActor::connect(&client, &address, Duration::from_secs(5));
    tally.add(value0).unwrap();
    let total = tally.add(value0).unwrap();
    client.close();
    server.close();
    total
}

pub async fn remoteDoubling(value0: i32) -> i64 {
    use crate::lawspec_sessions::doubling;
    let server = ls::net::Node::new(ls::net::HttpTransport::local().unwrap());
    let client = ls::net::Node::new(ls::net::HttpTransport::local().unwrap());
    let first = doubling::listen(&server, "doubling").unwrap();
    let second = doubling::dial(&client, &format!("{}/doubling", server.address())).unwrap();
    let worker = std::thread::spawn(move || {
        let (x, reply) = second.receive();
        let _ = reply.send(2 * i64::from(x));
    });
    let (result, _) = first.send(value0).receive();
    worker.join().unwrap();
    client.close();
    server.close();
    result
}
