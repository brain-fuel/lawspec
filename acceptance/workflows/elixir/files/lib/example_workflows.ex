# ref:DEC-acceptance-with-mutants
defmodule Example.Workflows do
  alias LawSpec.Data
  def audit(_), do: true
  def waitlist(%Data.SignupErrorUnavailable{}), do: {:right, %Data.Account{name: "waitlist", age: 18, level: 0}}
  def waitlist(error), do: {:left, error}
  def check_name(%Data.Signup{name: ""}), do: {:left, %Data.SignupErrorMissingName{}}
  def check_name(signup), do: {:right, signup}
  def check_age(%Data.Signup{age: age}) when age < 18, do: {:left, "too young"}
  def check_age(signup), do: {:right, signup}
  def open_account(%Data.Signup{name: "taken"}), do: {:left, %Data.SignupErrorUnavailable{}}
  def open_account(%Data.Signup{name: name, age: age}), do: {:right, %Data.Account{name: name, age: age, level: 1}}
  def check_stock(%Data.Order{number: n} = order) do
    if n == -1, do: Process.sleep(400)
    if n < 0, do: {:left, "no stock"}, else: {:right, order}
  end
  def check_credit(%Data.Order{number: n} = order) do
    if n == -1, do: Process.sleep(250)
    if n < 0, do: {:left, "no credit"}, else: {:right, order}
  end
end
