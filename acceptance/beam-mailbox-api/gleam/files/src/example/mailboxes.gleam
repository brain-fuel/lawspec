// ref:DEC-tests-cite-requirements ref:DEC-distribution-canonical-wire
import gleam/option.{None, Some}
import lawspec/data
import lawspec/network
import lawspec/scalar
import lawspec/abilities/lawspec/time as clock
import lawspec/mailboxes/example/mailboxes/jobs
import lawspec/mailboxes/example/mailboxes/notices
import lawspec/mailboxes/example/mailboxes/identities

@external(erlang, "beam_mailbox_probe", "with_nodes")
fn with_nodes(body: fn(network.Node, network.Node) -> a) -> a
@external(erlang, "beam_mailbox_probe", "rejects")
fn rejects(body: fn() -> a) -> Bool

pub fn native_probe(_unit: Nil) -> Bool {
  jobs.with_mailbox(fn(box) {
    let job = data.Job("parcel", 42)
    jobs.send(box, job)
    let assert True = jobs.receive_value(box) == job
    let clock = clock.clock(fn() { data.Instant(0) }, fn(duration) {
      let assert data.Duration(10_000_000) = duration
      jobs.send(box, job)
    })
    let assert None = jobs.receive_with_clock(box, 10_000_000, clock)
    let assert Some(data.Job("parcel", 42)) = jobs.receive_within(box, 0)
    let assert True = rejects(fn() { jobs.send(box, data.Job("bad", 2_147_483_648)) })
    jobs.close(box)
    let assert True = rejects(fn() { jobs.receive_value(box) })
  })
  notices.with_mailbox(fn(box) {
    notices.send(box, Nil)
    let assert Some(Nil) = notices.receive_within(box, 0)
    let assert None = notices.receive_within(box, 0)
  })
  identities.with_mailbox(fn(box) {
    let identity = scalar.symbol("job")
    identities.send(box, identity)
    let assert True = scalar.symbol_equal(identity, identities.receive_value(box))
  })
  use a, b <- with_nodes
  let box = jobs.serve(a, "jobs")
  let sender = jobs.connect(b, jobs.address(box), 2000)
  let job = data.Job("remote", 7)
  jobs.send_remote(sender, job)
  let assert True = jobs.receive_value(box) == job
  let assert None = jobs.receive_within(box, 1000)
  jobs.close(box)
  rejects(fn() { jobs.send_remote(sender, job) })
}
