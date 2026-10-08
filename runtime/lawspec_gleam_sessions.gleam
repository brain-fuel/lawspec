// Native session tasks own their channel ends until they complete or delegate.
// ref:DEC-sessions-by-construction ref:DEC-async-native-tasks
pub type Task(result)

@external(erlang, "lawspec_beam_session_task", "join")
pub fn join(task: Task(result)) -> result

@external(erlang, "lawspec_beam_session_task", "cancel")
pub fn cancel(task: Task(result)) -> Nil
