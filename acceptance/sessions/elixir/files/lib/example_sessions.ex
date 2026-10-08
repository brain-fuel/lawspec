# ref:DEC-tests-cite-requirements ref:DEC-sessions-by-construction
defmodule Example.Sessions do
  alias LawSpec.Sessions.Example.Sessions.{Serve, Hire}

  defp serve(server) do
    {a, s1} = Serve.first_receive_0(server)
    {b, s2} = Serve.first_receive_1(s1)
    Serve.first_send_2(s2, a + b)
    :ok
  end
  defp ask(client, a, b) do
    c1 = Serve.second_send_0(client, a)
    c2 = Serve.second_send_1(c1, b)
    {total, _} = Serve.second_receive_2(c2)
    total
  end
  defp manage(manager) do
    {server, _} = Hire.second_receive_0(manager)
    serve(server)
  end

  def add(a, b) do
    Serve.with_pair(fn server, client ->
      task = Serve.spawn_first(server, &serve/1)
      total = ask(client, a, b)
      :ok = LawSpec.Sessions.join(task)
      total
    end)
  end
  def add_hired(a, b) do
    Hire.with_pair(fn boss, manager ->
      Serve.with_pair(fn server, client ->
        task = Hire.spawn_second(manager, &manage/1)
        Hire.first_send_0(boss, server)
        total = ask(client, a, b)
        :ok = LawSpec.Sessions.join(task)
        total
      end)
    end)
  end
end
