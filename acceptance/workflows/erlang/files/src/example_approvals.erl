%% ref:DEC-acceptance-with-mutants
-module(example_approvals).
-export([approved_quickly/1, approval_errors/1]).
approved_quickly(N) -> lawspec_beam_workflow:with_real(0, fun(_) ->
    Start = erlang:monotonic_time(millisecond),
    example_workflows_definitions:approve({order, N}),
    erlang:monotonic_time(millisecond) - Start < 550
end).
approval_errors(N) -> lawspec_beam_workflow:with_real(0, fun(_) ->
    case example_workflows_definitions:approve({order, N}) of
        {right, _} -> [];
        {left, {approve_error_approve_failures, Errors}} -> [Error || {_, Error} <- Errors]
    end
end).
