#!/usr/bin/env escript
%%! -noshell
%% Build once before Rebar/Mix/Gleam compilation; no compiler runs at application
%% startup. CC names one executable. LAWSPEC_OPENSSL_PREFIX selects a development
%% installation matching OTP's OpenSSL major version (3.5+).
%% ref:DEC-typed-core-boundary
-mode(compile).

main(Arguments) ->
    try
        Project = case Arguments of
            [] -> filename:dirname(filename:absname(escript:script_name()));
            [Directory] -> filename:absname(Directory);
            _ -> fail("usage: escript lawspec_crypto_build.escript [project-directory]")
        end,
        build(Project)
    catch
        throw:{build_error, Message} -> io:format(standard_error, "LawSpec crypto: ~ts~n", [Message]), halt(1);
        error:Reason -> io:format(standard_error, "LawSpec crypto build failed: ~tp~n", [Reason]), halt(1)
    end.

build(Project) ->
    case list_to_integer(erlang:system_info(otp_release)) >= 29 of
        true -> ok;
        false -> fail("Erlang/OTP 29 or newer is required")
    end,
    [{<<"OpenSSL">>, Version, Description}] = crypto:info_lib(),
    Major = Version bsr 28,
    MissingAlgorithms = lists:append([Expected -- crypto:supports(Kind) || {Kind, Expected} <-
        [{kems, [mlkem768]}, {public_keys, [mldsa65, slh_dsa_shake_128f]},
         {hashs, [sha3_256, shake256]}, {ciphers, [aes_256_gcm]}]]),
    case MissingAlgorithms of
        [] -> ok;
        Missing -> fail(io_lib:format("OTP crypto lacks ~tp; install OTP with OpenSSL 3.5+", [Missing]))
    end,
    Compiler = executable(env("CC", "cc")),
    {Include, Library, ProviderVersion} = openssl(Major),
    OtpInclude = filename:join([code:root_dir(), "usr", "include"]),
    Source = filename:join([Project, "priv", "lawspec_crypto_native.c"]),
    Output = filename:join([Project, "priv", "lawspec_crypto_native.so"]),
    Stamp = Output ++ ".build",
    SourceBytes = read(Source),
    Args = ["-std=c11", "-O2", "-Wall", "-Wextra", "-Werror", "-fPIC", "-shared"] ++
        platform_flags() ++ ["-DLAWSPEC_OPENSSL_MAJOR=" ++ integer_to_list(Major),
        "-I" ++ OtpInclude, "-I" ++ Include, Source, "-L" ++ Library,
        "-Xlinker", "-rpath", "-Xlinker", Library, "-lcrypto"],
    Fingerprint = crypto:hash(sha3_256, term_to_binary({SourceBytes,
        read(escript:script_name()), read(filename:join(Include, "openssl/opensslv.h")),
        read(filename:join(OtpInclude, "erl_nif.h")),
        erlang:system_info(system_architecture), erlang:system_info(nif_version),
        Version, Description, ProviderVersion, Compiler, Args})),
    case current(Stamp, Output, Fingerprint) of
        true -> ok;
        false ->
            %% A failed or concurrent build cannot replace a working library.
            Temporary = Output ++ "." ++ os:getpid() ++ ".tmp",
            try
                checked(Compiler, Args ++ ["-o", Temporary]),
                ok = file:rename(Temporary, Output),
                ok = file:write_file(Stamp, term_to_binary({Fingerprint, crypto:hash(sha3_256, read(Output))})),
                io:format("Built LawSpec crypto bridge (~ts).~n", [Description])
            after
                file:delete(Temporary)
            end
    end.

platform_flags() ->
    case os:type() of
        {unix, darwin} -> ["-undefined", "dynamic_lookup"];
        {unix, _} -> [];
        _ -> fail("the crypto bridge build requires a Unix C toolchain; use WSL on Windows")
    end.

openssl(Major) ->
    case os:getenv("LAWSPEC_OPENSSL_PREFIX") of
        false -> discover_openssl(Major);
        Prefix -> prefix(Prefix, "explicit prefix")
    end.

discover_openssl(Major) ->
    case os:find_executable("pkg-config") of
        false -> homebrew_openssl(Major);
        Pkg ->
            case run(Pkg, ["--modversion", "libcrypto"]) of
                {0, Text} ->
                    Version = string:trim(binary_to_list(Text)),
                    case string:prefix(Version, integer_to_list(Major) ++ ".") of
                        nomatch -> homebrew_openssl(Major);
                        _ -> {query(Pkg, ["--variable=includedir", "libcrypto"]),
                              query(Pkg, ["--variable=libdir", "libcrypto"]), Version}
                    end;
                _ -> homebrew_openssl(Major)
            end
    end.

homebrew_openssl(Major) ->
    case os:find_executable("brew") of
        false -> missing_openssl(Major);
        Brew ->
            case run(Brew, ["--prefix", "openssl@" ++ integer_to_list(Major)]) of
                {0, Text} -> prefix(string:trim(binary_to_list(Text)), "Homebrew");
                _ -> missing_openssl(Major)
            end
    end.

prefix(Prefix, Origin) ->
    Absolute = filename:absname(Prefix),
    Include = filename:join(Absolute, "include"),
    case filelib:is_regular(filename:join(Include, "openssl/evp.h")) of
        true ->
            Libraries = [filename:join(Absolute, Subdir) || Subdir <- ["lib", "lib64"],
                lists:any(fun(Name) -> filelib:is_regular(filename:join([Absolute, Subdir, Name])) end,
                    ["libcrypto.so", "libcrypto.dylib"])],
            case Libraries of
                [Library | _] -> {Include, Library, Origin};
                [] -> fail("OpenSSL shared library missing under " ++ Absolute)
            end;
        false -> fail("OpenSSL headers missing under " ++ Absolute)
    end.

missing_openssl(Major) -> fail(io_lib:format(
    "install pkg-config and OpenSSL ~B development headers/libraries (3.5+), or set LAWSPEC_OPENSSL_PREFIX to that installation", [Major])).

current(Stamp, Output, Fingerprint) ->
    case {file:read_file(Stamp), file:read_file(Output)} of
        {{ok, StampBytes}, {ok, OutputBytes}} ->
            try binary_to_term(StampBytes, [safe]) =:= {Fingerprint, crypto:hash(sha3_256, OutputBytes)}
            catch error:badarg -> false end;
        _ -> false
    end.

env(Key, Default) -> case os:getenv(Key) of false -> Default; Value -> Value end.
executable(Name) -> case os:find_executable(Name) of
    false -> fail("executable not found: " ++ Name ++ " (CC must name one compiler executable)");
    Path -> Path
end.

read(Path) -> case file:read_file(Path) of
    {ok, Bytes} -> Bytes;
    {error, Reason} -> fail(io_lib:format("cannot read ~ts: ~tp", [Path, Reason]))
end.

query(Command, Args) -> string:trim(binary_to_list(checked(Command, Args))).
checked(Command, Args) -> case run(Command, Args) of
    {0, Output} -> Output;
    {Status, Output} -> fail(io_lib:format("~ts exited ~B:~n~ts", [Command, Status, Output]))
end.

%% Argument arrays, never a shell: project and installation paths may contain
%% spaces, quotes, dollar signs or other shell metacharacters.
run(Command, Args) ->
    Port = open_port({spawn_executable, Command}, [binary, exit_status, use_stdio, stderr_to_stdout, {args, Args}]),
    collect(Port, []).

collect(Port, Parts) ->
    receive
        {Port, {data, Bytes}} -> collect(Port, [Bytes | Parts]);
        {Port, {exit_status, Status}} -> {Status, iolist_to_binary(lists:reverse(Parts))}
    end.

fail(Message) -> throw({build_error, lists:flatten(Message)}).
