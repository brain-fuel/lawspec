%% @doc Lexically scoped ability evidence and typed failures on the BEAM.
%% The schema carries immutable handler choices; symbol identity is unchanged.
%% Stateful handlers and recordings belong to a monitored scope, so parallel
%% workers share their state and cancellation cannot leak handler processes.
%% ref:DEC-typed-core-boundary
-module(lawspec_beam_effects).
-behaviour(gen_server).
-export([with_scope/3, install/2, handler/2, stateless/1, stateful/3,
    recording/2, perform/4, invoke/4, count_calls/4,
    fail/1, raise_failure/2, attempt/4, native_failures/4, match_exception/3,
    native_origin/0, origin/5, recover_handler/5, with_native_context/3,
    native_cell/1, native_read/1, native_write/2]).
-export_type([context/0, handler_origin/0]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).

-opaque context() :: {lawspec_context, map(), reference()}.
-opaque handler_origin() :: none | {lawspec_handler_origin, binary(), map(), reference(), term(), [function()]}.

native_origin() -> none.

%% A native interface can cross back into a checked definition. Retaining its
%% logical handler lets that definition supply its current lexical context,
%% including any nested override of another ability used by a spec clause.
origin(Schema, Symbols, Ability, Handler, Operations) ->
    {lawspec_handler_origin, Ability, Schema, Symbols, Handler, Operations}.

recover_handler({lawspec_handler_origin, Ability, _, Symbols, Handler, Operations}, Ability, Symbols, Operations, _) -> Handler;
recover_handler(none, _, _, _, Make) -> Make();
recover_handler({lawspec_handler_origin, Ability, _, Symbols, _, _}, Ability, Symbols, _, Make) -> Make();
recover_handler({lawspec_handler_origin, Ability, _, _, _, _}, Ability, _, _, _) ->
    erlang:error({lawspec, incompatible_handler_contexts});
recover_handler(_, Ability, _, _, _) -> erlang:error({lawspec, {invalid_handler_origin, Ability}}).

with_native_context(Origins, SchemaFactory, Body) ->
    Contexts = [{Schema, Symbols} || {lawspec_handler_origin, _, Schema, Symbols, _, _} <- Origins],
    {Schema, Symbols} = case Contexts of
        [] -> Fresh = make_ref(), {SchemaFactory(Fresh), Fresh};
        [{FirstSchema, FirstSymbols} | Rest] ->
            case lists:all(fun({_, S}) -> S =:= FirstSymbols end, Rest) of
                true -> {FirstSchema, FirstSymbols};
                false -> erlang:error({lawspec, incompatible_handler_contexts})
            end
    end,
    with_scope(Schema, #{}, fun(Scoped) -> Body(Scoped, Symbols) end).

%% Factories run inside the scope as well: a later factory failing releases
%% any state already allocated by earlier factories.
with_scope(Schema, Factories, Body) ->
    {ok, Scope} = gen_server:start(?MODULE, self(), []),
    Base = Schema#{lawspec_scope => Scope},
    Previous = put({?MODULE, scope}, Scope),
    try
        Handlers = maps:map(fun(_, Make) -> Make(Base) end, Factories),
        Body(install(Base, Handlers))
    after
        case Previous of
            undefined -> erase({?MODULE, scope});
            _ -> put({?MODULE, scope}, Previous)
        end,
        try gen_server:stop(Scope, normal, infinity)
        catch exit:noproc -> ok end
    end.

%% Native production factories may allocate scoped state without receiving a
%% hidden argument. Only allocation uses this process-local scope; the cell
%% itself is a shareable process and all access is serialized by its server.
native_cell(Initial) ->
    case get({?MODULE, scope}) of
        Scope when is_pid(Scope) -> cell(#{lawspec_scope => Scope}, Initial);
        _ -> erlang:error({lawspec, missing_handler_scope})
    end.

native_read(Cell) -> lawspec_beam_handler:call(Cell, fun(Value) -> {Value, Value} end).
native_write(Cell, Value) -> lawspec_beam_handler:call(Cell, fun(_) -> {Value, Value} end).

install(Schema, Handlers) ->
    Schema#{lawspec_handlers => maps:merge(maps:get(lawspec_handlers, Schema, #{}), Handlers)}.

handler(Schema, Ability) ->
    case maps:find(Ability, maps:get(lawspec_handlers, Schema, #{})) of
        {ok, Handler} -> Handler;
        error -> erlang:error({lawspec, {missing_handler, Ability}})
    end.

stateless(Operations) -> {lawspec_handler, Operations}.

stateful(Schema, Initial, Operations) ->
    {lawspec_stateful, cell(Schema, Initial), Operations}.

recording(Schema, Handler) ->
    {lawspec_recording, cell(Schema, []), Handler}.

cell(#{lawspec_scope := Scope}, Initial) ->
    gen_server:call(Scope, {cell, Initial}, infinity);
cell(_, _) -> erlang:error({lawspec, missing_handler_scope}).

perform(Schema, Ability, Operation, Arguments) ->
    invoke(handler(Schema, Ability), Schema, Operation, Arguments).

invoke({lawspec_handler, Operations}, Schema, Operation, Arguments) ->
    Clause = operation(Operations, Operation),
    Clause(Schema, Arguments);
invoke({lawspec_stateful, Cell, Operations}, Schema, Operation, Arguments) ->
    Clause = operation(Operations, Operation),
    Path = maps:get(lawspec_effect_path, Schema, []),
    case lists:member(Cell, Path) of
        true -> erlang:error({lawspec, {recursive_handler_call, Operation}});
        false -> lawspec_beam_handler:call(Cell, fun(State) ->
            Clause(Schema#{lawspec_effect_path => [Cell | Path]}, Arguments, State)
        end)
    end;
invoke({lawspec_recording, Cell, Inner}, Schema, Operation, Arguments) ->
    %% Record the attempted call even if the wrapped operation aborts.
    lawspec_beam_handler:call(Cell, fun(Log) -> {ok, [{Operation, Arguments} | Log]} end),
    invoke(Inner, Schema, Operation, Arguments).

operation(Operations, Name) ->
    case maps:find(Name, Operations) of
        {ok, Clause} -> Clause;
        error -> erlang:error({lawspec, {missing_handler_operation, Name}})
    end.

count_calls(Schema, Ability, Operation, Arguments) ->
    case handler(Schema, Ability) of
        {lawspec_recording, Cell, _} ->
            Calls = lawspec_beam_handler:call(Cell, fun(Log) -> {Log, Log} end),
            length([ok || {Name, Values} <- Calls, Name =:= Operation,
                Arguments =:= any orelse lawspec_beam_scalar:equal(Values, Arguments)]);
        _ -> erlang:error({lawspec, {recording_required, Ability}})
    end.

%% Native code uses fail/1 with its native failure value. The adapter's
%% declared Fail ability determines how that value crosses the boundary.
fail(Value) -> throw({lawspec_native_failure, Value}).
raise_failure(Ability, Value) -> throw({lawspec_failure, Ability, Value}).

attempt(Ability, Body, Right, Left) ->
    try Body() of
        Value -> Right(Value)
    catch throw:{lawspec_failure, Ability, Value} -> Left(Value) end.

%% Each optional native exception mapping returns no_match or {ok, Value}.
%% Existing typed failures pass through unchanged, including another ability.
native_failures(Ability, Convert, Body, Mappings) ->
    try Body() catch
        throw:{lawspec_native_failure, Native} -> raise_failure(Ability, Convert(Native));
        throw:{lawspec_failure, _, _} = Failure:Stack -> erlang:raise(throw, Failure, Stack);
        Class:Reason:Stack ->
            case mapped(Mappings, Class, Reason) of
                {ok, Value} -> raise_failure(Ability, Value);
                no_match -> erlang:raise(Class, Reason, Stack)
            end
    end.

mapped([], _, _) -> no_match;
mapped([Map | Rest], Class, Reason) ->
    case Map(Class, Reason) of
        no_match -> mapped(Rest, Class, Reason);
        {ok, _} = Found -> Found
    end.

%% Native mappings name an Elixir exception module or a tagged Erlang error
%% reason (also available to Gleam FFI code). They do not catch exits, throws,
%% or an unrelated error merely because its printed message contains the tag.
match_exception({elixir, Module}, error,
        #{'__struct__' := Module, '__exception__' := true} = Exception) ->
    {ok, 'Elixir.Exception':message(Exception)};
match_exception({tag, Tag}, error, Tag) -> {ok, atom_to_binary(Tag, utf8)};
match_exception({tag, Tag}, error, Reason) when is_tuple(Reason), tuple_size(Reason) > 0,
        element(1, Reason) =:= Tag ->
    Message = case Reason of
        {Tag, Text} when is_binary(Text) -> Text;
        _ -> unicode:characters_to_binary(io_lib:format("~tp", [Reason]))
    end,
    {ok, Message};
match_exception(_, _, _) -> no_match.

init(Owner) -> {ok, #{owner => monitor(process, Owner), cells => #{}}}.

handle_call({cell, Initial}, _, State = #{cells := Cells}) ->
    {ok, Cell} = lawspec_beam_handler:start(self(), Initial),
    Monitor = monitor(process, Cell),
    {reply, Cell, State#{cells := Cells#{Monitor => Cell}}}.

handle_cast(_, State) -> {noreply, State}.

handle_info({'DOWN', Owner, process, _, _}, State = #{owner := Owner}) ->
    {stop, normal, State};
handle_info({'DOWN', Monitor, process, _, _}, State = #{cells := Cells}) ->
    {noreply, State#{cells := maps:remove(Monitor, Cells)}};
handle_info(_, State) -> {noreply, State}.

terminate(_, #{cells := Cells}) ->
    maps:foreach(fun(_, Cell) -> lawspec_beam_handler:stop(Cell) end, Cells).
