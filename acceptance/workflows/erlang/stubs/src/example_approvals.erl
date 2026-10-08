%% User-owned LawSpec adapter. Implement these functions.
-module(example_approvals).
-export([approved_quickly/1, approval_errors/1]).

-spec approved_quickly(-9223372036854775808..9223372036854775807) -> boolean().

approved_quickly(_Argument0) ->
    erlang:error({not_implemented, <<"example.approvals::approvedQuickly"/utf8>>}).

-spec approval_errors(-9223372036854775808..9223372036854775807) -> [binary()].

approval_errors(_Argument0) ->
    erlang:error({not_implemented, <<"example.approvals::approvalErrors"/utf8>>}).
