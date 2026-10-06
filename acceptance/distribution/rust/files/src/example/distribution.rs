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

pub async fn remoteLedger(value0: i32) -> i64 {
    use crate::lawspec_mailboxes::LedgerMailbox;
    let here = ls::net::Node::new(ls::net::TcpTransport::local().unwrap());
    let there = ls::net::Node::new(ls::net::TcpTransport::local().unwrap());
    let ledger = LedgerMailbox::serve(&there, "ledger").unwrap();
    let sender = LedgerMailbox::connect(&here, &format!("{}/ledger", there.address()), Duration::from_secs(5));
    sender.send(i64::from(value0)).unwrap();
    sender.send(i64::from(value0)).unwrap();
    let total = ledger.receive(Some(Duration::from_secs(5))).unwrap() + ledger.receive(Some(Duration::from_secs(5))).unwrap();
    // receive within: nothing more comes, so it gives None in time.
    let more = ledger.receive_within(Duration::from_millis(20)).unwrap();
    here.close();
    there.close();
    if more.is_some() { -1 } else { total }
}

pub async fn remoteHandoff(value0: i32) -> i64 {
    use crate::lawspec_sessions::{doubling, handoff};
    let here = ls::net::Node::new(ls::net::TcpTransport::local().unwrap());
    let there = ls::net::Node::new(ls::net::TcpTransport::local().unwrap());
    // A local conversation on this node; its first end goes to the other.
    let (first, second) = doubling::open();
    let worker = std::thread::spawn(move || {
        let (x, reply) = second.receive();
        let _ = reply.send(2 * i64::from(x));
    });
    let giving = handoff::listen(&here, "handoff").unwrap();
    let taking = handoff::dial(&there, &format!("{}/handoff", here.address())).unwrap();
    let _ = giving.send(first);
    let (end, _) = taking.receive();
    let (result, _) = end.send(value0).receive();
    worker.join().unwrap();
    there.close();
    here.close();
    result
}

pub async fn remoteHandoffOnward(value0: i32) -> i64 {
    use crate::lawspec_sessions::{answering, passing};
    let network = ls::net::MemoryNetwork::new(value0 as u64 & 0xFFFF, 0.1, 0.1, Duration::from_millis(5));
    let [a, b, c, d] = ["a", "b", "c", "d"].map(|n| ls::net::Node::new(network.transport(n)));
    // A conversation between A and C, which sends at once; A's end moves to
    // B, then to D, and answers from there.
    let first = answering::listen(&a, "answering").unwrap();
    let second = answering::dial(&c, &format!("{}/answering", a.address())).unwrap().send(value0);
    let to_b = passing::listen(&a, "to-b").unwrap();
    let at_b = passing::dial(&b, &format!("{}/to-b", a.address())).unwrap();
    let _ = to_b.send(first);
    let (moved, _) = at_b.receive();
    let to_d = passing::listen(&b, "to-d").unwrap();
    let at_d = passing::dial(&d, &format!("{}/to-d", b.address())).unwrap();
    let _ = to_d.send(moved);
    let (end, _) = at_d.receive();
    // The end no longer needs A or B.
    a.close();
    b.close();
    let (x, reply) = end.receive();
    let _ = reply.send(2 * i64::from(x));
    let (result, _) = second.receive();
    c.close();
    d.close();
    result
}

pub async fn sealedOnTheWire(value0: i32) -> bool {
    // A definition evaluated on another node: its request names the
    // definition's content hash, which shows on the wire only in the clear.
    let name = "example.distribution::shifted";
    let digest = crate::lawspec_remote::digest(name).expect("a remote definition").as_bytes().to_vec();
    let mut seen = [false, false];
    for (i, insecure) in [false, true].into_iter().enumerate() {
        let network = ls::net::MemoryNetwork::new(value0 as u64 & 0xFFFF, 0.0, 0.0, Duration::ZERO).with_recording();
        let make = |node: &str| if insecure { network.insecure_transport_for_tests(node) } else { network.transport(node) };
        let here = ls::net::Node::new(make("here"));
        let there = ls::net::Node::new(make("there"));
        crate::lawspec_remote::serve(&there).unwrap();
        let result = crate::lawspec_remote::evaluate(&here, &there.address(), name, &[ls::IntoValue::into_value(value0)]);
        here.close();
        there.close();
        let Ok(result) = result else { return false };
        let Ok(result) = <i64 as ls::FromValue>::from_value(result) else { return false };
        if result != i64::from(value0) + 1000 {
            return false;
        }
        seen[i] = network.recorded().iter().any(|record| record.windows(digest.len()).any(|w| w == digest.as_slice()));
    }
    seen == [false, true]
}

pub fn handshakeAgrees(value0: String) -> bool {
    let fields: Vec<&str> = value0.split(' ').collect();
    let &[a, b, c, d, e, f, g, h, i, j, k, l, m] = fields.as_slice() else { return false };
    crate::lawspec_network::handshake_vector(a, b, c, d, e, f, g, h, i, j, k, l, m)
}
