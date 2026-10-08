%% @doc The seed and vector bridge to the same OpenSSL ABI as OTP crypto.
%% Build with escript lawspec_crypto_build.escript; ship the resulting priv/.
%% ref:DEC-typed-core-boundary
-module(lawspec_beam_crypto_native).
-on_load(init/0).
-export([expand/2, encapsulate_test/2, sign_context/5, verify_context/5]).

init() ->
    [{<<"OpenSSL">>, Version, _}] = crypto:info_lib(),
    BeamDir = filename:dirname(code:which(?MODULE)),
    %% Application layouts (Rebar, Mix, Gleam and releases) put ebin beside
    %% priv. The second path supports a standalone erlc output directory.
    Candidates = [filename:join([filename:dirname(BeamDir), "priv", "lawspec_crypto_native"]),
        filename:join([BeamDir, "priv", "lawspec_crypto_native"])],
    case [Path || Path <- Candidates, filelib:is_regular(Path ++ extension())] of
        [Library | _] -> erlang:load_nif(Library, Version bsr 28);
        [] -> {error, {load_failed,
            "LawSpec crypto bridge is missing; run escript lawspec_crypto_build.escript before compiling and ship priv/ with the application"}}
    end.

extension() -> case os:type() of {win32, _} -> ".dll"; _ -> ".so" end.

expand(_, _) -> erlang:nif_error(lawspec_crypto_native_not_loaded).
encapsulate_test(_, _) -> erlang:nif_error(lawspec_crypto_native_not_loaded).
sign_context(_, _, _, _, _) -> erlang:nif_error(lawspec_crypto_native_not_loaded).
verify_context(_, _, _, _, _) -> erlang:nif_error(lawspec_crypto_native_not_loaded).
