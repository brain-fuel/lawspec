%% @doc Coverage for Gleam's native test VM. Export after suite cleanup so
%% release callbacks count, and keep the beam paths needed to map Gleam lines.
%% ref:REQ-harness-units ref:DEC-native-property-frameworks
-module(lawspec_beam_coverage).
-export([start/0, finish/1]).

start() ->
    case os:getenv("LAWSPEC_BEAM_COVERAGE") of
        false -> none;
        Text -> start(json:decode(unicode:characters_to_binary(Text)))
    end.

start(#{<<"run">> := Run, <<"file">> := File, <<"metadata">> := Metadata}) ->
    {ok, _} = cover:start(),
    try
        Directory = filename:dirname(code:which(lawspec_beam_runtime)),
        %% Gleam's generated VM launcher is still on the boot process stack.
        %% Recompiling and later purging it would kill the VM during stop/0.
        %% It is compiler scaffolding, with no application source to measure.
        Beams = [Beam || Beam <- filelib:wildcard(filename:join(Directory, "*.beam")),
            not lists:suffix("@@main.beam", Beam)],
        true = Beams =/= [],
        Modules = [begin
            {ok, Module} = cover:compile_beam(Beam),
            #{name => atom_to_binary(Module), beam => unicode:characters_to_binary(filename:absname(Beam))}
        end || Beam <- Beams],
        #{run => Run, file => File, metadata => Metadata, modules => Modules}
    catch Class:Reason:Stack ->
        cover:stop(), erlang:raise(Class, Reason, Stack)
    end.

finish(none) -> ok;
finish(#{file := File, metadata := Metadata} = Run) ->
    try
        ok = cover:export(unicode:characters_to_list(File)),
        ok = file:write_file(Metadata, json:encode(maps:remove(metadata, Run)))
    after cover:stop() end.
