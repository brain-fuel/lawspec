# Native session tasks. ref:DEC-sessions-by-construction ref:DEC-async-native-tasks
defmodule LawSpec.Sessions do
  @opaque task :: :lawspec_beam_session_task.task()

  @spec join(task()) :: term()
  def join(task), do: :lawspec_beam_session_task.join(task)

  @spec cancel(task()) :: :ok
  def cancel(task), do: :lawspec_beam_session_task.stop(task)
end
