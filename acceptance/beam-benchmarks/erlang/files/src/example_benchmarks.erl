%% ref:REQ-harness-units
-module(example_benchmarks).
-export([ordinary/1, work/1, async_work/1, false_value/1, meter_handler/0]).
ordinary(N) -> beam_benchmark_support:record(<<"ordinary">>, N).
work(N) -> beam_benchmark_support:record(<<"sync">>, N).
async_work(N) -> beam_benchmark_support:record(<<"async">>, N).
false_value(ok) -> beam_benchmark_support:record(<<"false">>, false).
meter_handler() -> #{read => fun(ok) -> beam_benchmark_support:record(<<"production">>, 1337) end}.
