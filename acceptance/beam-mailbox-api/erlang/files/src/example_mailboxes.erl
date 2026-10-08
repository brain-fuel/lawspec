%% ref:DEC-tests-cite-requirements ref:DEC-distribution-canonical-wire
-module(example_mailboxes).
-export([native_probe/1]).

native_probe(ok) ->
    lawspec_mailbox_example_mailboxes_jobs:with_mailbox(fun(Box) ->
        Job = {job, <<"parcel">>, 42},
        ok = lawspec_mailbox_example_mailboxes_jobs:send(Box, Job),
        Job = lawspec_mailbox_example_mailboxes_jobs:receive_value(Box),
        Clock = #{now => fun() -> {instant, 0} end, sleep => fun({duration, 10000000}) ->
            lawspec_mailbox_example_mailboxes_jobs:send(Box, Job), ok
        end},
        nothing = lawspec_mailbox_example_mailboxes_jobs:receive_with_clock(Box, 10000000, Clock),
        {just, Job} = lawspec_mailbox_example_mailboxes_jobs:receive_within(Box, 0),
        true = beam_mailbox_probe:rejects(fun() -> lawspec_mailbox_example_mailboxes_jobs:send(Box, {job, <<"bad">>, 2147483648}) end),
        ok = lawspec_mailbox_example_mailboxes_jobs:close(Box),
        true = beam_mailbox_probe:rejects(fun() -> lawspec_mailbox_example_mailboxes_jobs:receive_value(Box) end)
    end),
    lawspec_mailbox_example_mailboxes_notices:with_mailbox(fun(Box) ->
        ok = lawspec_mailbox_example_mailboxes_notices:send(Box, ok),
        {just, ok} = lawspec_mailbox_example_mailboxes_notices:receive_within(Box, 0),
        nothing = lawspec_mailbox_example_mailboxes_notices:receive_within(Box, 0)
    end),
    lawspec_mailbox_example_mailboxes_identities:with_mailbox(fun(Box) ->
        Identity = lawspec_beam_scalar:new_symbol(<<"job">>),
        ok = lawspec_mailbox_example_mailboxes_identities:send(Box, Identity),
        Identity = lawspec_mailbox_example_mailboxes_identities:receive_value(Box)
    end),
    beam_mailbox_probe:with_nodes(fun(A, B) ->
        Box = lawspec_mailbox_example_mailboxes_jobs:serve(A, <<"jobs">>),
        Sender = lawspec_mailbox_example_mailboxes_jobs:connect(B, lawspec_mailbox_example_mailboxes_jobs:address(Box), 2000),
        Job = {job, <<"remote">>, 7},
        ok = lawspec_mailbox_example_mailboxes_jobs:send_remote(Sender, Job),
        Job = lawspec_mailbox_example_mailboxes_jobs:receive_value(Box),
        nothing = lawspec_mailbox_example_mailboxes_jobs:receive_within(Box, 1000),
        ok = lawspec_mailbox_example_mailboxes_jobs:close(Box),
        beam_mailbox_probe:rejects(fun() -> lawspec_mailbox_example_mailboxes_jobs:send_remote(Sender, Job) end)
    end).
