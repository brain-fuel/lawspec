# ref:DEC-tests-cite-requirements ref:DEC-distribution-canonical-wire
defmodule Example.Mailboxes do
  alias LawSpec.Mailboxes.Example.Mailboxes.{JobsMailbox, NoticesMailbox, IdentitiesMailbox}
  alias LawSpec.Data.{Job, Instant, Duration}
  alias LawSpec.Abilities.Lawspec.Time.Clock

  def native_probe(:ok) do
    JobsMailbox.with_mailbox(fn box ->
      job = %Job{label: "parcel", amount: 42}
      :ok = JobsMailbox.send(box, job)
      ^job = JobsMailbox.receive_value(box)
      clock = %Clock{now: fn -> %Instant{value: 0} end, sleep: fn %Duration{value: 10000000} ->
        JobsMailbox.send(box, job)
      end}
      :nothing = JobsMailbox.receive_with_clock(box, 10000000, clock)
      {:just, ^job} = JobsMailbox.receive_within(box, 0)
      true = :beam_mailbox_probe.rejects(fn -> JobsMailbox.send(box, %Job{label: "bad", amount: 2147483648}) end)
      :ok = JobsMailbox.close(box)
      true = :beam_mailbox_probe.rejects(fn -> JobsMailbox.receive_value(box) end)
    end)
    NoticesMailbox.with_mailbox(fn box ->
      :ok = NoticesMailbox.send(box, :ok)
      {:just, :ok} = NoticesMailbox.receive_within(box, 0)
      :nothing = NoticesMailbox.receive_within(box, 0)
    end)
    IdentitiesMailbox.with_mailbox(fn box ->
      identity = :lawspec_beam_scalar.new_symbol("job")
      :ok = IdentitiesMailbox.send(box, identity)
      ^identity = IdentitiesMailbox.receive_value(box)
    end)
    :beam_mailbox_probe.with_nodes(fn a, b ->
      box = JobsMailbox.serve(a, "jobs")
      sender = JobsMailbox.connect(b, JobsMailbox.address(box), 2000)
      job = %Job{label: "remote", amount: 7}
      :ok = JobsMailbox.send_remote(sender, job)
      ^job = JobsMailbox.receive_value(box)
      :nothing = JobsMailbox.receive_within(box, 1000)
      :ok = JobsMailbox.close(box)
      :beam_mailbox_probe.rejects(fn -> JobsMailbox.send_remote(sender, job) end)
    end)
  end
end
