# ref:DEC-acceptance-with-mutants
defmodule Native.Failures.Negative do
  defexception [:message]
end

defmodule Native.Failures.Blocked do
  defexception message: "blocked"
end
