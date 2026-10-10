%% User-owned LawSpec adapter: native handlers of Logs, Reader and Writer
%% that share the case's Store, an ETS table of each log's records.
-module(example_composition).
-export([open_store/1, close_store/1, logs_handler/1, reader_handler/1, writer_handler/1]).

-spec open_store(ok) -> lawspec_data:store().
open_store(ok) -> ets:new(composition_store, [set, public]).

-spec close_store(lawspec_data:store()) -> ok.
close_store(Store) ->
    ets:delete(Store),
    ok.

-spec logs_handler(lawspec_data:store()) -> lawspec_abilities_example_composition:logs().
logs_handler(Store) ->
    #{
        create => fun(Log) ->
            ets:insert(Store, {Log, []}),
            ok
        end,
        append => fun(Log, Record) ->
            case ets:lookup(Store, Log) of
                [] -> lawspec_beam_effects:fail(problem_unknown_log);
                [{_, _}] when Record =:= <<>> -> lawspec_beam_effects:fail(problem_empty_record);
                [{_, Records}] ->
                    ets:insert(Store, {Log, Records ++ [Record]}),
                    length(Records)
            end
        end
    }.

-spec reader_handler(lawspec_data:store()) -> lawspec_abilities_example_composition:reader().
reader_handler(Store) ->
    #{
        size => fun(Log) ->
            case ets:lookup(Store, Log) of
                [] -> nothing;
                [{_, Records}] -> {just, length(Records)}
            end
        end
    }.

-spec writer_handler(lawspec_data:store()) -> lawspec_abilities_example_composition:writer().
writer_handler(Store) ->
    Last = lawspec_beam_effects:native_cell(nothing),
    #{
        write => fun(Log, Record) ->
            case ets:lookup(Store, Log) of
                [{_, Records}] when Record =/= <<>> ->
                    ets:insert(Store, {Log, Records ++ [Record]}),
                    lawspec_beam_effects:native_write(Last, {just, length(Records)}),
                    true;
                _ -> false
            end
        end,
        last_offset => fun() -> lawspec_beam_effects:native_read(Last) end
    }.
