defmodule PaymentsDomain.Dollars do
  defstruct []
  @type t :: %__MODULE__{}
end

defmodule PaymentsDomain.Euros do
  defstruct []
  @type t :: %__MODULE__{}
end

defmodule PaymentsDomain.Pounds do
  defstruct []
  @type t :: %__MODULE__{}
end

defmodule PaymentsDomain.CurrencyCode do
  @type t :: PaymentsDomain.Dollars.t() | PaymentsDomain.Euros.t() | PaymentsDomain.Pounds.t()
end

defmodule PaymentsDomain.Price do
  # Application field names and order deliberately differ from the specification.
  defstruct [:unit, :major]
  @type t :: %__MODULE__{unit: PaymentsDomain.CurrencyCode.t(), major: :lawspec_beam_scalar.decimal()}
end

defmodule PaymentsDomain.Settled do
  defstruct [:price]
  @type t :: %__MODULE__{price: PaymentsDomain.Price.t()}
end

defmodule PaymentsDomain.Rejected do
  defstruct [:explanation]
  @type t :: %__MODULE__{explanation: String.t()}
end

defmodule PaymentsDomain.PaymentStatus do
  @type t :: PaymentsDomain.Settled.t() | PaymentsDomain.Rejected.t()
end

defmodule PaymentsDomain do
  alias PaymentsDomain.{Price, PaymentStatus}

  @spec apply_fee(Price.t()) :: Price.t()
  def apply_fee(%Price{major: amount} = price) do
    fee = :lawspec_beam_scalar.decimal(2, -1)
    %{price | major: :lawspec_beam_scalar.binary("+", amount, fee, "Decimal", "Decimal")}
  end

  @spec restore(PaymentStatus.t()) :: PaymentStatus.t()
  def restore(payment), do: payment

  @spec store([:nothing | {:just, PaymentStatus.t()}]) :: [:nothing | {:just, PaymentStatus.t()}]
  def store(payments), do: payments
end
