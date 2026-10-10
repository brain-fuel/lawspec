%% @doc Native runner boundaries for shared resource cleanup. EUnit uses a
%% setup/cleanup fixture; Gleam runs its ordinary EUnit tests and Gleeunit
%% reporter inside the same boundary before choosing the process exit code.
%% ref:REQ-harness-units ref:DEC-native-property-frameworks
-module(lawspec_beam_test_run).
-export([setup/0, cleanup/1, fixture/1, gleam_main/0, select_units/1, select/2]).

fixture(Tests) -> {setup, fun setup/0, fun cleanup/1, fun(_) -> Tests end}.

setup() ->
    case code:ensure_loaded(lawspec_beam_resources) of
        {module, lawspec_beam_resources} ->
            {ok, Run} = lawspec_beam_resources:start_suite(), Run;
        {error, nofile} -> none;
        Error -> error({lawspec, {resource_runtime_unavailable, Error}})
    end.
cleanup(none) -> ok;
cleanup(Run) -> lawspec_beam_resources:close(Run).

%% Only generated unit/name pairs can be selected. Keep one native run and
%% resource lifetime across units, and preserve scheduling within each unit.
select_units(Units) ->
    case law_selection() of
        all -> [Run() || {_, Run} <- Units];
        Selection ->
            Names = lists:usort([Unit || {Unit, _} <- Selection]),
            unknown(Names -- [Unit || {Unit, _} <- Units]),
            [Run() || {Unit, Run} <- Units, lists:member(Unit, Names)]
    end.

select(Unit, Groups) ->
    case law_selection() of
        all -> [Group || {_, Group} <- Groups];
        Selection ->
            Names = [Name || {SelectedUnit, Name} <- Selection, SelectedUnit =:= Unit],
            unknown(Names -- [Name || {Name, _} <- Groups]),
            [Group || {Name, Group} <- Groups, lists:member(Name, Names)]
    end.

law_selection() ->
    case os:getenv("LAWSPEC_BEAM_LAWS") of
        false -> all;
        Text ->
            Rows = json:decode(unicode:characters_to_binary(Text)),
            true = is_list(Rows) andalso Rows =/= [],
            true = lists:all(fun
                (#{<<"unit">> := Unit, <<"name">> := Name}) -> is_binary(Unit) andalso selected_name(Name);
                (_) -> false
            end, Rows),
            lists:usort([{Unit, Name} || #{<<"unit">> := Unit, <<"name">> := Name} <- Rows])
    end.

selected_name(<<"law_", _/binary>>) -> true;
selected_name(<<"model_", _/binary>>) -> true;
selected_name(<<"supervision">>) -> true;
selected_name(_) -> false.

unknown([]) -> ok;
unknown(Names) -> error({lawspec, {unknown_test_selection, Names}}).

%% Gleeunit's main/0 calls erlang:halt/1 directly, which cannot unwind a
%% surrounding cleanup scope. Keep its file discovery and native reporter,
%% but finish resource cleanup before halting, including after failed tests.
gleam_main() ->
    Code = try
        Coverage = lawspec_beam_coverage:start(),
        Result = try
            Run = setup(),
            try
                Modules = lists:usort([test_module(Path) || Path <- filelib:wildcard("**/*.{erl,gleam}", "test")]),
                Tests = gleam_selection(Modules),
                eunit:test(Tests, [verbose, no_tty, {report, {gleeunit_progress, [{colored, true}]}},
                    {report, {lawspec_beam_report, []}}, {scale_timeouts, 10}])
            after cleanup(Run) end
        after lawspec_beam_coverage:finish(Coverage) end,
        case Result of ok -> 0; _ -> 1 end
    catch Class:Reason:Stack ->
        io:format(standard_error, "LawSpec test run failed: ~tp:~tp~n~tp~n", [Class, Reason, Stack]), 1
    end,
    erlang:halt(Code).

%% The CLI selects exact native benchmark functions through structured data;
%% never turn environment text into Erlang source or run undiscovered modules.
gleam_selection(Modules) ->
    case os:getenv("LAWSPEC_BEAM_BENCHMARKS") of
        false -> case law_selection() of
            all -> [gleam_tests(Module) || Module <- Modules];
            _ ->
                Units = [begin
                    {module, Module} = code:ensure_loaded(Module),
                    case erlang:function_exported(Module, lawspec_unit, 0) of
                        true -> [{Module:lawspec_unit(), fun Module:lawspec_suite/0}];
                        false -> []
                    end
                end || Module <- Modules],
                select_units(lists:append(Units))
        end;
        Text ->
            Selected = json:decode(unicode:characters_to_binary(Text)),
            true = is_list(Selected) andalso Selected =/= [],
            [begin
                [Module] = [M || M <- Modules, atom_to_binary(M) =:= ModuleName],
                {module, Module} = code:ensure_loaded(Module),
                [Function] = [F || {F,0} <- Module:module_info(exports), atom_to_binary(F) =:= FunctionName,
                    lists:prefix("benchmark_", atom_to_list(F)), lists:suffix("__case_0_test", atom_to_list(F))],
                {timeout, 60, erlang:make_fun(Module, Function, 0)}
            end || #{<<"module">> := ModuleName, <<"function">> := FunctionName} <- validated_selection(Selected)]
    end.

validated_selection(Selected) ->
    true = lists:all(fun
        (#{<<"module">> := Module, <<"function">> := Function}) -> is_binary(Module) andalso is_binary(Function);
        (_) -> false
    end, Selected),
    lists:usort(Selected).

%% Generated scheduled units expose a suite descriptor referencing their
%% native Gleam test functions. Do not also auto-discover those functions:
%% that would execute the same checks twice. Other modules use normal EUnit.
gleam_tests(Module) ->
    {module, Module} = code:ensure_loaded(Module),
    case erlang:function_exported(Module, lawspec_suite, 0) of
        true -> {generator, fun Module:lawspec_suite/0};
        false -> Module
    end.

test_module(Path) ->
    Name = case filename:extension(Path) of
        ".gleam" -> [case C of $/ -> $@; _ -> C end || C <- filename:rootname(Path)];
        ".erl" -> filename:basename(Path, ".erl")
    end,
    list_to_atom(Name).
