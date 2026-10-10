# ref:DEC-tests-cite-requirements ref:DEC-stateful-models-linearizability
defmodule Example.Handles do
  def new_jobs(:ok), do: :beam_jobs.new()
  def submit(jobs, value) do
    true = :beam_jobs.submit(jobs, value)
    :ok
  end
  def take(jobs), do: :beam_jobs.take(jobs)
  def pending(jobs), do: :beam_jobs.pending(jobs)
end
