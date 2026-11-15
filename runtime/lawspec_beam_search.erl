%% @doc LawSpec's descriptor search, separate from native property generation
%% and shrinking. Matches the portable seeded climb: ten starting points,
%% sixty rounds, at most twenty-four moves per round and four hundred checks.
%% The checked callback rejects refinements before invoking the law. These
%% trials do not change the property test's coverage denominator.
%% ref:REQ-harness-units ref:DEC-portable-seeded-generation
-module(lawspec_beam_search).
-export([climb/3, moves/3, remember/3, replay/3, guard/4, kept_record/3, kept_replay/6, kept_admit/3]).

%% Native frameworks still generate and shrink. Keep each failing candidate,
%% so the final counterexample can run before the next generated cases, even
%% when a generator or its version has changed. Use the shared wire encoding.
%% ref:REQ-harness-units ref:DEC-shrink-within-domain
guard(Law, Descriptors, Values, Check) ->
    try Check() of
        false ->
            keep(Law, Descriptors, Values),
            false;
        Result ->
            Result
    catch
        Kind:Reason:Stack ->
            keep(Law, Descriptors, Values),
            erlang:raise(Kind, Reason, Stack)
    end.

keep(Law, Descriptors, Values) ->
    %% Failure reporting must not replace the original native assertion.
    try
        remember(Law, Descriptors, Values)
    catch
        Kind:Reason ->
            io:format(
                standard_error,
                "LawSpec could not save inputs for ~ts: ~tp:~tp~n",
                [Law, Kind, Reason]
            )
    end.

remember(Law, Descriptors, Values) ->
    case input_file(Law) of
        none ->
            ok;
        File ->
            Inputs = [
                begin
                    {Table, D} = lawspec_beam_values:from_text(Descriptor),
                    binary:encode_hex(lawspec_beam_values:encode(D, Value, Table), lowercase)
                end
             || {Descriptor, Value} <- lists:zip(Descriptors, Values)
            ],
            ok = filelib:ensure_dir(File),
            Temporary =
                File ++ "." ++ os:getpid() ++ "." ++
                    integer_to_list(erlang:unique_integer([positive])) ++ ".tmp",
            try
                ok = file:write_file(Temporary, json:encode(#{law => Law, inputs => Inputs}), [
                    exclusive
                ]),
                ok = file:rename(Temporary, File)
            after
                file:delete(Temporary)
            end
    end.

%% Check includes the current refinements, before any adapter or resource is
%% used. A failing replay leaves its inputs intact; a repaired or obsolete
%% counterexample is removed. Replays do not count as generated observations.
replay(Law, Descriptors, Check) ->
    case input_file(Law) of
        none ->
            ok;
        File ->
            case file:read_file(File) of
                {error, enoent} ->
                    ok;
                {error, Reason} ->
                    lawspec_beam_harness:abort({failure_inputs_read, Law, Reason});
                {ok, Bytes} ->
                    case read_inputs(Law, Descriptors, Bytes) of
                        stale ->
                            io:format(
                                standard_error, "~ts: discarding incompatible saved inputs~n", [Law]
                            );
                        {ok, Values} ->
                            io:format(
                                standard_error,
                                "~ts: replaying the failing inputs kept in .lawspec/failures~n",
                                [Law]
                            ),
                            case Check(Values) of
                                false -> erlang:error({lawspec, {replay_failed, Law}});
                                _ -> ok
                            end
                    end,
                    case file:delete(File) of
                        ok ->
                            ok;
                        {error, enoent} ->
                            ok;
                        {error, Reason} ->
                            lawspec_beam_harness:abort({failure_inputs_delete, Law, Reason})
                    end
            end
    end.

read_inputs(Law, Descriptors, Bytes) ->
    try
        #{<<"law">> := Law, <<"inputs">> := Inputs} = json:decode(Bytes),
        Values = [
            begin
                {Table, D} = lawspec_beam_values:from_text(Descriptor),
                lawspec_beam_values:decode(D, binary:decode_hex(Hex), Table)
            end
         || {Descriptor, Hex} <- lists:zip(Descriptors, Inputs)
        ],
        {ok, Values}
    catch
        _:_ -> stale
    end.

input_file(Law) ->
    case os:getenv("LAWSPEC_FAILURES") of
        false ->
            none;
        "" ->
            none;
        Directory ->
            %% Labels may differ only by punctuation. Hash the whole identity
            %% rather than replacing punctuation with colliding underscores.
            Name = binary_to_list(binary:encode_hex(crypto:hash(sha256, Law), lowercase)),
            filename:join([Directory, "inputs", Name ++ ".json"])
    end.

%% The kept-values store (docs/reference/cli.md, "Kept values"). A run that
%% draws a case holding a value of a restricted type records the case's
%% inputs in the wire encoding under .lawspec/found, in a file named by a hash
%% of the definitions its inputs reach, so a changed restriction makes the old
%% values unreachable. A later run replays them as extra cases of the law
%% after checking each against the current definitions; one that no longer
%% meets them is dropped. A spec is "KEY CAP TAG...": the cap is how many
%% values a key keeps (0 keeps none), the tags are the constructors of the
%% restricted types.
kept_record(Spec, Descriptors, Values) ->
    Key = {lawspec_kept_recorded, Spec},
    case persistent_term:get(Key, false) of
        true ->
            ok;
        false ->
            [Name, Cap | Tags] = string:lexemes(Spec, " "),
            case kept_file(Name) of
                none ->
                    persistent_term:put(Key, true);
                _ when Cap =:= "0" ->
                    persistent_term:put(Key, true);
                File ->
                    case kept_holds(Values, [list_to_binary(T) || T <- Tags]) of
                        false ->
                            ok;
                        true ->
                            persistent_term:put(Key, true),
                            try
                                Inputs = [
                                    binary:encode_hex(lawspec_beam_values:encode(D, V, Table), lowercase)
                                 || {Descriptor, V} <- lists:zip(Descriptors, Values),
                                    {Table, D} <- [lawspec_beam_values:from_text(Descriptor)]
                                ],
                                kept_update(File, Name, list_to_integer(Cap), fun(Entries) ->
                                    Same = [E || #{<<"inputs">> := I} = E <- Entries, I =:= Inputs],
                                    [E || #{<<"inputs">> := I} = E <- Entries, I =/= Inputs] ++
                                        case Same of
                                            [E | _] -> [E];
                                            [] -> [#{<<"inputs">> => Inputs, <<"used">> => 0}]
                                        end
                                end)
                            catch
                                _:_ -> ok
                            end
                    end
            end
    end.

%% Admit(Values) is true when the values meet the current definitions and the
%% law's own input refinements; Check(Values) then runs the law.
kept_replay(Law, Spec, Descriptors, Admit, Check, _Bits) ->
    [Name, Cap | _] = string:lexemes(Spec, " "),
    case {kept_file(Name), list_to_integer(Cap)} of
        {none, _} ->
            ok;
        {_, 0} ->
            ok;
        {File, Limit} ->
            Entries = kept_read(File),
            Considered = lists:nthtail(max(0, length(Entries) - Limit), Entries),
            Outcomes = [
                begin
                    Inputs = maps:get(<<"inputs">>, Entry),
                    Decoded =
                        try
                            {ok, [
                                lawspec_beam_values:decode(D, binary:decode_hex(Hex), Table)
                             || {Descriptor, Hex} <- lists:zip(Descriptors, Inputs),
                                {Table, D} <- [lawspec_beam_values:from_text(Descriptor)]
                            ]}
                        catch
                            _:_ -> error
                        end,
                    case Decoded of
                        {ok, Values} ->
                            case Admit(Values) of
                                true ->
                                    case Check(Values) of
                                        false -> erlang:error({lawspec, {kept_value_failed, Law}});
                                        none -> {dropped, Inputs};
                                        _ -> {used, Inputs}
                                    end;
                                false ->
                                    {dropped, Inputs}
                            end;
                        error ->
                            {dropped, Inputs}
                    end
                end
             || Entry <- Considered
            ],
            Dropped = [I || {dropped, I} <- Outcomes],
            Used = [I || {used, I} <- Outcomes],
            case Dropped ++ Used of
                [] ->
                    ok;
                _ ->
                    kept_update(File, Name, Limit, fun(Current) ->
                        [
                            case lists:member(I, Used) of
                                true -> E#{<<"used">> := maps:get(<<"used">>, E) + 1};
                                false -> E
                            end
                         || #{<<"inputs">> := I} = E <- Current, not lists:member(I, Dropped)
                        ]
                    end)
            end,
            case Used of
                [] ->
                    ok;
                _ ->
                    io:format(
                        standard_error,
                        "~ts: ran ~b kept value(s) found by earlier runs in .lawspec/found~n",
                        [Law, length(Used)]
                    )
            end
    end.

%% Whether each value meets the current definitions of its type.
kept_admit(Values, References, Schema) ->
    try
        _ = [lawspec_beam_schema:validate(V, Ref, Schema) || {V, Ref} <- lists:zip(Values, References)],
        true
    catch
        _:_ -> false
    end.

kept_file(Name) ->
    Directory =
        case os:getenv("LAWSPEC_FOUND") of
            Found when Found =/= false, Found =/= "" ->
                Found;
            _ ->
                case os:getenv("LAWSPEC_FAILURES") of
                    Failures when Failures =/= false, Failures =/= "" ->
                        %% The failure database is .lawspec/failures/<target>/<project>.
                        filename:join([Failures, "..", "..", "..", "found"]);
                    _ ->
                        none
                end
        end,
    case Directory of
        none -> none;
        _ -> filename:join(Directory, Name ++ ".json")
    end.

kept_read(File) ->
    try
        {ok, Bytes} = file:read_file(File),
        #{<<"values">> := Values} = json:decode(Bytes),
        [E || #{<<"inputs">> := I, <<"used">> := U} = E <- Values, is_list(I), is_integer(U)]
    catch
        _:_ -> []
    end.

%% Merge into what is on disk now, since another target's run may have
%% written since this one read: write a temporary file, then rename it.
kept_update(File, Name, Limit, Change) ->
    Entries = Change(kept_read(File)),
    Kept = lists:nthtail(max(0, length(Entries) - Limit), Entries),
    Directory = filename:dirname(File),
    case filelib:is_dir(Directory) of
        true ->
            ok;
        false ->
            ok = filelib:ensure_dir(File),
            ok = file:write_file(filename:join(Directory, ".gitignore"), "*\n")
    end,
    Temporary = File ++ "." ++ os:getpid() ++ "." ++ integer_to_list(erlang:unique_integer([positive])) ++ ".tmp",
    try
        ok = file:write_file(Temporary, [json:encode(#{<<"key">> => list_to_binary(Name), <<"values">> => Kept}), "\n"]),
        ok = file:rename(Temporary, File)
    after
        file:delete(Temporary)
    end.

kept_holds(Values, Tags) when is_list(Values) ->
    lists:any(fun(V) -> kept_holds(V, Tags) end, Values);
kept_holds({ls_data, Tag, Fields}, Tags) ->
    lists:member(Tag, Tags) orelse kept_holds(Fields, Tags);
kept_holds(_, _) ->
    false.

climb(Law, Descriptors, Check) ->
    Seed =
        case os:getenv("LAWSPEC_SEED") of
            false -> 0;
            Text -> list_to_integer(Text)
        end,
    Tables = [lawspec_beam_values:from_text(D) || D <- Descriptors],
    Initial = #{tried => 0, accepted => 0, best => none, values => none},
    try
        Start = lists:foldl(
            fun(K, State) ->
                {_, Next} = attempt(generate(Tables, Seed + K), Check, State),
                Next
            end,
            Initial,
            lists:seq(0, 9)
        ),
        Final = climb_rounds(0, Seed, Tables, Check, Start),
        publish(Law, Seed, passed, Final),
        ok
    catch
        throw:{search_failed, Kind, Reason, Stack, State, Values} ->
            keep(Law, Descriptors, Values),
            Inputs = [
                binary:encode_hex(lawspec_beam_values:encode(D, V, Table))
             || {{Table, D}, V} <- lists:zip(Tables, Values)
            ],
            try
                publish(Law, Seed, failed, State)
            catch
                ReportKind:ReportReason ->
                    io:format(
                        standard_error,
                        "LawSpec search statistics failed for ~ts: ~tp:~tp~n",
                        [Law, ReportKind, ReportReason]
                    )
            end,
            erlang:raise(
                error,
                {lawspec, {target_failed, Law, {seed, Seed}, {inputs, Inputs}, {Kind, Reason}}},
                Stack
            )
    end.

generate(Tables, Seed) ->
    {Values, _} = lists:mapfoldl(
        fun({Table, D}, S) -> lawspec_beam_values:generate(D, Table, S, 8) end,
        lawspec_beam_random:seed(Seed),
        Tables
    ),
    Values.

attempt(_, _, #{tried := N} = State) when N >= 400 -> {false, State};
attempt(Values, Check, #{tried := N, accepted := Accepted, best := Best} = State) ->
    Next = State#{tried := N + 1},
    try
        case Check(Values) of
            none ->
                {false, Next};
            {score, Score} ->
                case lawspec_beam_harness:higher(Score, Best) of
                    true ->
                        {true, Next#{
                            accepted := Accepted + 1, best := {score, Score}, values := Values
                        }};
                    false ->
                        {false, Next#{accepted := Accepted + 1}}
                end
        end
    catch
        Kind:Reason:Stack -> throw({search_failed, Kind, Reason, Stack, Next, Values})
    end.

climb_rounds(60, _, _, _, State) ->
    State;
climb_rounds(_, _, _, _, #{tried := N} = State) when N >= 400 -> State;
climb_rounds(Step, Seed, Tables, Check, #{values := Values} = State) ->
    Candidates =
        case Values of
            none -> [];
            _ -> lists:sublist(input_moves(Tables, Values), 24)
        end,
    {Rose, Next} = lists:foldl(
        fun(Candidate, {AlreadyRose, Current}) ->
            {Rising, After} = attempt(Candidate, Check, Current),
            {AlreadyRose orelse Rising, After}
        end,
        {false, State},
        Candidates
    ),
    After =
        case Rose of
            true ->
                Next;
            false ->
                {_, Redrawn} = attempt(generate(Tables, Seed + 1000 + Step), Check, Next),
                Redrawn
        end,
    climb_rounds(Step + 1, Seed, Tables, Check, After).

input_moves([], []) ->
    [];
input_moves([{Table, D} | Tables], [V | Values]) ->
    [[Candidate | Values] || Candidate <- moves(D, V, Table)] ++
        [[V | Tail] || Tail <- input_moves(Tables, Values)].

%% Each move changes one integer leaf and remains within its wire bounds.
%% Other refinements, including relationships between inputs, belong to the
%% typed callback and are checked again before any adapter/resource is used.
moves(D, Value, Table) -> moves_resolved(lawspec_beam_values:resolve(D, Table), Value, Table).
moves_resolved([<<"int">>, _, _, _] = D, N, _) ->
    {Lo, Hi} = bounds(D),
    unique(
        [
            X
         || X <- [N + 1, N - 1, N * 2, N div 2, N + (Hi - N) div 2, N - (N - Lo) div 2],
            X =/= N,
            X >= Lo,
            X =< Hi
        ],
        []
    );
moves_resolved([<<"list">>, D], Values, Table) ->
    field_moves([D || _ <- Values], Values, Table);
moves_resolved([<<"maybe">>, D], {ls_data, <<"Maybe::Present">> = Tag, [V]}, Table) ->
    [{ls_data, Tag, [C]} || C <- moves(D, V, Table)];
moves_resolved([<<"either">>, A, B], {ls_data, Tag, [V]}, Table) ->
    D =
        case Tag of
            <<"Either::Left">> -> A;
            <<"Either::Right">> -> B
        end,
    [{ls_data, Tag, [C]} || C <- moves(D, V, Table)];
moves_resolved([<<"data">>, _ | Constructors], {ls_data, Tag, Values}, Table) ->
    [Types] = [Ds || [<<"ctor">>, Name | Ds] <- Constructors, unquote(Name) =:= Tag],
    [{ls_data, Tag, Cs} || Cs <- field_moves(Types, Values, Table)];
moves_resolved(_, _, _) ->
    [].

field_moves([], [], _) ->
    [];
field_moves([D | Ds], [V | Vs], Table) ->
    [[C | Vs] || C <- moves(D, V, Table)] ++ [[V | Cs] || Cs <- field_moves(Ds, Vs, Table)].

unique([], _) ->
    [];
unique([X | Xs], Seen) ->
    case lists:member(X, Seen) of
        true -> unique(Xs, Seen);
        false -> [X | unique(Xs, [X | Seen])]
    end.
unquote({quoted, Name}) -> Name;
unquote(Name) -> Name.

%% The shared descriptor's finite exploration window for unbounded integers.
bounds([<<"int">>, _, none, none]) -> {-1000000, 1000000};
bounds([<<"int">>, _, none, Hi]) -> {min(-1000000, Hi - 2000000), Hi};
bounds([<<"int">>, _, Lo, none]) -> {Lo, max(1000000, Lo + 2000000)};
bounds([<<"int">>, _, Lo, Hi]) -> {Lo, Hi}.

publish(Law, Seed, Outcome, #{tried := Tried, accepted := Accepted, best := Best}) ->
    BestText =
        case Best of
            none -> null;
            {score, Score} -> lawspec_beam_harness:score_text(Score)
        end,
    io:format("~ts: targeted search tried ~B case(s)~ts~n", [
        Law,
        Tried,
        case BestText of
            null -> <<>>;
            _ -> <<"; best score ", BestText/binary>>
        end
    ]),
    lawspec_beam_harness:record(#{
        law => Law,
        test => <<Law/binary, " search">>,
        attempts => 1,
        outcome => atom_to_binary(Outcome),
        search => #{
            seed => integer_to_binary(Seed),
            tried => Tried,
            accepted => Accepted,
            best => BestText
        }
    }).
