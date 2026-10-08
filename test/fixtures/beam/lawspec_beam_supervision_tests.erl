%% @doc Generated supervision evidence runs independently of a framework
%% and releases every owned process without consuming application messages.
%% ref:DEC-tests-cite-requirements ref:DEC-actors-otp-supervision
-module(lawspec_beam_supervision_tests).
-include_lib("eunit/include/eunit.hrl").

supervision_evidence_uses_real_otp_semantics_test() ->
    ?assertEqual(ok, lawspec_beam_supervision:check()).

supervision_evidence_preserves_callers_mailbox_test() ->
    %% Other runtime tests intentionally leave monitor events with their
    %% EUnit caller. Use a fresh application caller for this isolation check.
    ok = lawspec_beam_runtime:async_call(fun mailbox_isolation/0).
mailbox_isolation() ->
    Other = {lawspec_actor, self(), [application_actor]},
    self() ! application_message,
    self() ! {lawspec_actor_event, Other, {stopped, none}},
    ?assertEqual(ok, lawspec_beam_supervision:check()),
    receive application_message -> ok after 0 -> error(application_message_consumed) end,
    receive {lawspec_actor_event, Other, {stopped, none}} -> ok after 0 -> error(application_event_consumed) end,
    receive {lawspec_actor_event, _, _} -> error(check_event_leaked);
        {lawspec_supervisor_event, _, _} -> error(check_event_leaked)
    after 0 -> ok end.

supervision_evidence_closes_all_owned_services_test() ->
    Before = services(),
    lists:foreach(fun(_) -> ok = lawspec_beam_supervision:check() end, lists:seq(1, 5)),
    wait_closed(Before, erlang:monotonic_time(millisecond) + 2000).
services() ->
    Modules = [lawspec_beam_actor_tree, lawspec_beam_actor_sup, lawspec_beam_actor, lawspec_beam_tasks],
    [Pid || Pid <- processes(), {dictionary, D} <- [process_info(Pid, dictionary)],
        {'$initial_call', {Module, _, _}} <- [lists:keyfind('$initial_call', 1, D)], lists:member(Module, Modules)].
wait_closed(Before, Deadline) ->
    case services() -- Before of
        [] -> ok;
        Remaining ->
            ?assert(erlang:monotonic_time(millisecond) < Deadline, {leaked_services, Remaining}),
            receive after 1 -> ok end, wait_closed(Before, Deadline)
    end.
