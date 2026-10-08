-module(example_handler_context).
-export([roundtrip/2, public_probe/1, counter_handler/0, offset_handler/0]).

roundtrip(Counter, Amount) -> example_handler_context_definitions:shifted(Counter, Amount).

public_probe(ok) ->
    lawspec_abilities:with_context(fun(Context) ->
        Counter = lawspec_abilities_example_handler_context:fresh_counter(Context),
        Recorded = lawspec_abilities_example_handler_context:recording_counter(Context, Counter),
        example_handler_context_definitions:advance(Recorded, 2) =:= 2 andalso
        example_handler_context_definitions:shifted(Recorded, 3) =:= 105
    end).

counter_handler() ->
    Total = lawspec_beam_effects:native_cell(0),
    #{bump => fun(Amount) ->
          lawspec_beam_effects:native_write(Total, lawspec_beam_effects:native_read(Total) + Amount)
      end,
      current => fun() -> lawspec_beam_effects:native_read(Total) end}.

offset_handler() -> #{offset => fun() -> 0 end}.
