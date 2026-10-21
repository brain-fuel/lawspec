# ref:DEC-acceptance-with-mutants
defmodule Example.Approvals do
  alias Example.Workflows.Definitions
  alias LawSpec.{Data, Workflow}
  # A fast order first loads the workflow's modules, so loading code is not
  # timed with the checks.
  def approved_quickly(n) do
    Workflow.with_real(fn _ ->
      Definitions.approve(%Data.Order{number: 0})
      # Whether two of order -1's slow checks that started during this call
      # overlapped in time. Run one after the other they cannot overlap,
      # however loaded the machine is.
      started = Example.Workflows.since()
      Definitions.approve(%Data.Order{number: n})
      n != -1 or Example.Workflows.overlapped?(started)
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
