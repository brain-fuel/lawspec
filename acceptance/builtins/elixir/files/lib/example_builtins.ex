defmodule Example.Builtins do
  def elapsed(clock, count) do
    start = clock.now.().value
    if count > 0, do: Enum.each(1..count, fn _ -> clock.now.() end)
    finish = clock.now.().value
    %LawSpec.Data.Duration{value: finish - start}
  end

  def token(secure_random, count), do: secure_random.secure_bytes.(count)

  def listening(ports, _count) do
    {:ok, socket} = :gen_tcp.listen(ports.free_port.(), ip: {127, 0, 0, 1}, active: false)
    :gen_tcp.close(socket)
    true
  end

  def charge(log, cents) do
    if rem(cents, 2) == 0 do
      log.log_message.(%LawSpec.Data.LogLevelInfo{}, "charged")
      true
    else
      false
    end
  end
end
