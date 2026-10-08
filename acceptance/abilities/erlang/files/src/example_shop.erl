%% Native factories allocate state owned by the current LawSpec scope.
-module(example_shop).
-export([refund/2, log_handler/0, store_int32_handler/0, store_text_handler/0, meter_handler/0]).

refund(_, Cents) when Cents > 100000 -> lawspec_beam_effects:fail(payment_error_too_large);
refund(Gateway, Cents) ->
    {receipt, Paid} = (maps:get(capture, Gateway))(Cents),
    Paid.

log_handler() ->
    Lines = lawspec_beam_effects:native_cell([]),
    #{note => fun(Text) ->
        _ = lawspec_beam_effects:native_write(Lines, [Text | lawspec_beam_effects:native_read(Lines)]),
        ok
    end}.

store_int32_handler() ->
    Stored = lawspec_beam_effects:native_cell(0),
    #{load => fun() -> lawspec_beam_effects:native_read(Stored) end,
      save => fun(Value) -> _ = lawspec_beam_effects:native_write(Stored, Value), ok end}.

store_text_handler() ->
    Stored = lawspec_beam_effects:native_cell(<<>>),
    #{load => fun() -> lawspec_beam_effects:native_read(Stored) end,
      save => fun(Text) -> _ = lawspec_beam_effects:native_write(Stored, Text), ok end}.

meter_handler() -> #{reading => fun() -> 3 end}.
