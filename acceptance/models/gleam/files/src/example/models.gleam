// ref:DEC-tests-cite-requirements ref:DEC-stateful-models-linearizability
import lawspec/data

pub fn empty(_unit: Nil) -> data.Stack { data.StackEmpty }
pub fn push(n: Int, s: data.Stack) -> data.PushFlow { data.PushFlow(data.StackPush(data.Recordd055baeeed41ba47fc1e56412cb39424d62fb8f1a3afa343166abc5bf09d2949(s, n))) }
pub fn pop(s: data.Stack) -> data.PopFlow {
  let assert data.StackPush(data.Recordd055baeeed41ba47fc1e56412cb39424d62fb8f1a3afa343166abc5bf09d2949(rest, n)) = s
  data.PopFlow(n, rest)
}
pub fn peek(s: data.Stack) -> data.PeekFlow {
  let assert data.StackPush(data.Recordd055baeeed41ba47fc1e56412cb39424d62fb8f1a3afa343166abc5bf09d2949(_, n)) = s
  data.PeekFlow(n, s)
}
pub fn new_counter(_unit: Nil) -> data.Counter { data.Counter(counter_new()) }
pub fn increment(c: data.Counter) -> Int { counter_increment(c.id) }
pub fn decrement(c: data.Counter) -> Int { counter_decrement(c.id) }
pub fn read(c: data.Counter) -> Int { counter_read(c.id) }

@external(erlang, "beam_model_counter", "new")
fn counter_new() -> Int
@external(erlang, "beam_model_counter", "increment")
fn counter_increment(id: Int) -> Int
@external(erlang, "beam_model_counter", "decrement")
fn counter_decrement(id: Int) -> Int
@external(erlang, "beam_model_counter", "read")
fn counter_read(id: Int) -> Int
