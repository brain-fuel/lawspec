# User-owned LawSpec adapter. Implement these functions.
defmodule Example.Workflows do
  @spec audit(LawSpec.Data.account()) :: boolean()

  def audit(_argument0) do raise "Not implemented: example.workflows::audit" end

  @spec waitlist(LawSpec.Data.signup_error()) ::
    {:left, LawSpec.Data.signup_error()} | {:right, LawSpec.Data.account()}

  def waitlist(_argument0) do raise "Not implemented: example.workflows::waitlist" end

  @spec check_stock(LawSpec.Data.order()) :: {:left, binary()} | {:right, LawSpec.Data.order()}

  def check_stock(_argument0) do raise "Not implemented: example.workflows::checkStock" end

  @spec check_credit(LawSpec.Data.order()) :: {:left, binary()} | {:right, LawSpec.Data.order()}

  def check_credit(_argument0) do raise "Not implemented: example.workflows::checkCredit" end

  @spec check_name(LawSpec.Data.signup()) ::
    {:left, LawSpec.Data.signup_error()} | {:right, LawSpec.Data.signup()}

  def check_name(_argument0) do raise "Not implemented: example.workflows::checkName" end

  @spec check_age(LawSpec.Data.signup()) :: {:left, binary()} | {:right, LawSpec.Data.signup()}

  def check_age(_argument0) do raise "Not implemented: example.workflows::checkAge" end

  @spec open_account(LawSpec.Data.signup()) ::
    {:left, LawSpec.Data.signup_error()} | {:right, LawSpec.Data.account()}

  def open_account(_argument0) do raise "Not implemented: example.workflows::openAccount" end
end
