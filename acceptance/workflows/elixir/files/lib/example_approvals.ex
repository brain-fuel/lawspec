# ref:DEC-acceptance-with-mutants
defmodule Example.Approvals do
  alias Example.Workflows.Definitions
  alias LawSpec.{Data, Workflow}
  def approved_quickly(n) do
    Workflow.with_real(fn _ ->
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
