defmodule PaymentGenerators do
  # StreamData.map preserves the integer generator's native shrink tree.
  def prices do
    StreamData.map(StreamData.integer(100..200), fn cents ->
      %PaymentsDomain.Price{unit: %PaymentsDomain.Euros{},
        major: :lawspec_beam_scalar.decimal(cents, -2)}
    end)
  end
end
