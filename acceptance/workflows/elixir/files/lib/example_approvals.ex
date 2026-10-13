# ref:DEC-acceptance-with-mutants
defmodule Example.Approvals do
  alias Example.Workflows.Definitions
  alias LawSpec.{Data, Workflow}
  # A fast order first loads the workflow's modules, so loading code is not
  # timed with the checks.
  def approved_quickly(n) do
    Workflow.with_real(fn _ ->
      Definitions.approve(%Data.Order{number: 0})
      started = System.monotonic_time(:millisecond)
      Definitions.approve(%Data.Order{number: n})
      System.monotonic_time(:millisecond) - started < 550
    end)
  end
  def approval_errors(n) do
    Workflow.with_real(fn _ ->
      case Definitions.approve(%Data.Order{number: n}) do
        {:right, _} -> []
        {:left, %Data.ApproveErrorApproveFailures{error: errors}} -> Enum.map(errors, & &1.error)
      end
    end)
  end
end
