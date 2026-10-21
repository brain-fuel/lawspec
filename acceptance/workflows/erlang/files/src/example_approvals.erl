%% ref:DEC-acceptance-with-mutants
-module(example_approvals).
-export([approved_quickly/1, approval_errors/1]).
%% A fast order first loads the workflow's modules, so loading code is not
%% timed with the checks.
approved_quickly(N) -> lawspec_beam_workflow:with_real(0, fun(_) ->
    example_workflows_definitions:approve({order, 0}),
    %% Whether two of order -1's slow checks that started during this call
    %% overlapped in time. Run one after the other they cannot overlap,
    %% however loaded the machine is.
    Since = example_workflows:since(),
    example_workflows_definitions:approve({order, N}),
    N =/= -1 orelse example_workflows:overlapped(Since)
end).
approval_errors(N) -> lawspec_beam_workflow:with_real(0, fun(_) ->
    case example_workflows_definitions:approve({order, N}) of
        {right, _} -> [];
        {left, {approve_error_approve_failures, Errors}} -> [Error || {_, Error} <- Errors]
    end
end).
