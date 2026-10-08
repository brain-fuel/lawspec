// ref:DEC-tests-cite-requirements ref:DEC-sessions-by-construction
import lawspec/sessions
import lawspec/sessions/example/sessions/serve
import lawspec/sessions/example/sessions/hire

fn serve_sum(server: serve.First0) -> Nil {
  let #(a, s1) = serve.first_receive_0(server)
  let #(b, s2) = serve.first_receive_1(s1)
  let _done = serve.first_send_2(s2, a + b)
  Nil
}
fn ask(client: serve.Second0, a: Int, b: Int) -> Int {
  let c1 = serve.second_send_0(client, a)
  let c2 = serve.second_send_1(c1, b)
  let #(total, _) = serve.second_receive_2(c2)
  total
}
fn manage(manager: hire.Second0) -> Nil {
  let #(server, _) = hire.second_receive_0(manager)
  serve_sum(server)
}

pub fn add(a: Int, b: Int) -> Int {
  use server, client <- serve.with_pair
  let task = serve.spawn_first(server, serve_sum)
  let total = ask(client, a, b)
  sessions.join(task)
  total
}
pub fn add_hired(a: Int, b: Int) -> Int {
  use boss, manager <- hire.with_pair
  use server, client <- serve.with_pair
  let task = hire.spawn_second(manager, manage)
  let _done = hire.first_send_0(boss, server)
  let total = ask(client, a, b)
  sessions.join(task)
  total
}
