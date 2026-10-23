%% User-owned LawSpec adapter. Implement these functions.
-module(example_beam_failures).
-export([refund/1, checked_limit/1]).

-spec refund(-2147483648..2147483647) -> -2147483648..2147483647.

refund(_Int32) -> erlang:error({not_implemented, <<"example.beamFailures::refund">>}).

-spec checked_limit(-2147483648..2147483647) -> -2147483648..2147483647.

checked_limit(_Int32) -> erlang:error({not_implemented, <<"example.beamFailures::checkedLimit">>}).
