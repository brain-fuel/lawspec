// Generated from templates/npm/beam-doctor.mjs by lawspec-dev generate. Do not edit.
import { access, mkdir, mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import os from "node:os";
import path from "node:path";

// These are the same sources the compiler emits, including the NIF loader.
const runtime = {
                  "formatter": "# Observe ExUnit's real skip events; excluded tests are not reported as run.\n# ref:REQ-harness-units ref:DEC-native-property-frameworks\ndefmodule LawSpec.Beam.ExUnitFormatter do\n  @moduledoc false\n  use GenServer\n\n  def init(_options), do: {:ok, :lawspec_beam_report.open()}\n\n  def handle_cast({:test_finished, %{state: {:skipped, _}, tags: %{lawspec_skip: {law, reason}}}}, state) do\n    :lawspec_beam_harness.skip(law, reason)\n    {:noreply, state}\n  end\n\n  def handle_cast({:test_finished, %{state: {:excluded, _}}}, state), do: {:noreply, state}\n  def handle_cast({:test_finished, %{state: {:skipped, _}}}, state), do: {:noreply, state}\n  def handle_cast({:test_finished, test}, state) do\n    :lawspec_beam_report.event(state, %{\n      event: \"test\", name: Atom.to_string(test.name), classname: inspect(test.module),\n      identity: Map.get(test.tags, :lawspec_identity, \"\"),\n      status: if(test.state == nil, do: \"passed\", else: \"failed\"),\n      time: (test.time || 0) / 1_000_000,\n      failure: if(test.state == nil, do: \"\", else: inspect(test.state, limit: :infinity, printable_limit: :infinity))\n    })\n    {:noreply, state}\n  end\n\n  def handle_cast({:suite_finished, _}, state) do\n    :lawspec_beam_report.finish(state)\n    {:noreply, state}\n  end\n\n  def handle_cast(_event, state), do: {:noreply, state}\nend\n",
                  "native": "%% @doc The seed and vector bridge to the same OpenSSL ABI as OTP crypto.\n%% Build with escript lawspec_crypto_build.escript; ship the resulting priv/.\n%% ref:DEC-typed-core-boundary\n-module(lawspec_beam_crypto_native).\n-on_load(init/0).\n-export([expand/2, encapsulate_test/2, sign_context/5, verify_context/5]).\n\ninit() ->\n    [{<<\"OpenSSL\">>, Version, _}] = crypto:info_lib(),\n    BeamDir = filename:dirname(code:which(?MODULE)),\n    %% Application layouts (Rebar, Mix, Gleam and releases) put ebin beside\n    %% priv. The second path supports a standalone erlc output directory.\n    Candidates = [filename:join([filename:dirname(BeamDir), \"priv\", \"lawspec_crypto_native\"]),\n        filename:join([BeamDir, \"priv\", \"lawspec_crypto_native\"])],\n    case [Path || Path <- Candidates, filelib:is_regular(Path ++ extension())] of\n        [Library | _] -> erlang:load_nif(Library, Version bsr 28);\n        [] -> {error, {load_failed,\n            \"LawSpec crypto bridge is missing; run escript lawspec_crypto_build.escript before compiling and ship priv/ with the application\"}}\n    end.\n\nextension() -> case os:type() of {win32, _} -> \".dll\"; _ -> \".so\" end.\n\nexpand(_, _) -> erlang:nif_error(lawspec_crypto_native_not_loaded).\nencapsulate_test(_, _) -> erlang:nif_error(lawspec_crypto_native_not_loaded).\nsign_context(_, _, _, _, _) -> erlang:nif_error(lawspec_crypto_native_not_loaded).\nverify_context(_, _, _, _, _) -> erlang:nif_error(lawspec_crypto_native_not_loaded).\n",
                  "c": "/* OpenSSL operations not exposed by OTP 29's crypto API: compact key seeds,\n * signature contexts and deterministic known-answer tests. Ordinary random\n * encapsulation, signing, verification and AEAD use OTP directly.\n * ref:DEC-typed-core-boundary\n */\n#include <erl_nif.h>\n#include <openssl/crypto.h>\n#include <openssl/evp.h>\n#include <openssl/err.h>\n#include <openssl/params.h>\n#include <openssl/core_names.h>\n#include <string.h>\n\n#if OPENSSL_VERSION_NUMBER < 0x30500000L\n#error \"LawSpec crypto requires OpenSSL 3.5 or newer\"\n#endif\n#if !defined(LAWSPEC_OPENSSL_MAJOR) || OPENSSL_VERSION_MAJOR != LAWSPEC_OPENSSL_MAJOR\n#error \"Build LawSpec crypto with the same OpenSSL major version as Erlang/OTP\"\n#endif\n\ntypedef struct {\n    const char *tag, *name;\n    size_t seed, public_key, private_key, signature;\n} Algorithm;\n\nstatic const Algorithm algorithms[] = {\n    {\"mlkem768\", \"ML-KEM-768\", 64, 1184, 2400, 0},\n    {\"mldsa65\", \"ML-DSA-65\", 32, 1952, 4032, 3309},\n    {\"slh_dsa_shake_128f\", \"SLH-DSA-SHAKE-128f\", 48, 32, 64, 17088}\n};\n\nstatic const Algorithm *algorithm(ErlNifEnv *env, ERL_NIF_TERM term) {\n    char tag[32];\n    size_t i;\n    if (!enif_get_atom(env, term, tag, sizeof(tag), ERL_NIF_LATIN1)) return NULL;\n    for (i = 0; i < sizeof(algorithms) / sizeof(algorithms[0]); ++i)\n        if (!strcmp(tag, algorithms[i].tag)) return &algorithms[i];\n    return NULL;\n}\n\n/* No key material or provider error strings enter diagnostics. OpenSSL's\n * per-thread error queue must not leak between jobs on a dirty scheduler. */\nstatic ERL_NIF_TERM failure(ErlNifEnv *env, const char *operation) {\n    ERR_clear_error();\n    return enif_raise_exception(env, enif_make_tuple2(env,\n        enif_make_atom(env, \"lawspec_crypto_failure\"), enif_make_atom(env, operation)));\n}\n\nstatic EVP_PKEY *import_key(const Algorithm *alg, const char *parameter,\n                           const ErlNifBinary *bytes, int selection) {\n    EVP_PKEY *key = NULL;\n    EVP_PKEY_CTX *ctx = EVP_PKEY_CTX_new_from_name(NULL, alg->name, NULL);\n    OSSL_PARAM params[] = {\n        OSSL_PARAM_construct_octet_string(parameter, bytes->data, bytes->size),\n        OSSL_PARAM_construct_end()\n    };\n    if (!ctx || EVP_PKEY_fromdata_init(ctx) <= 0\n        || EVP_PKEY_fromdata(ctx, &key, selection, params) <= 0) {\n        EVP_PKEY_free(key);\n        key = NULL;\n    }\n    EVP_PKEY_CTX_free(ctx);\n    return key;\n}\n\nstatic ERL_NIF_TERM expand(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {\n    const Algorithm *alg;\n    ErlNifBinary seed, pub = {0}, priv = {0};\n    EVP_PKEY_CTX *ctx = NULL;\n    EVP_PKEY *key = NULL;\n    size_t written;\n    int pub_allocated = 0, priv_allocated = 0, ok = 0;\n    ERL_NIF_TERM result;\n    if (argc != 2 || !(alg = algorithm(env, argv[0]))\n        || !enif_inspect_binary(env, argv[1], &seed) || seed.size != alg->seed)\n        return enif_make_badarg(env);\n    ERR_clear_error();\n    if (alg == &algorithms[2]) {\n        /* SLH's seed parameter is used only for the NIST key-generation tests. */\n        OSSL_PARAM params[] = {\n            OSSL_PARAM_construct_octet_string(\"seed\", seed.data, seed.size),\n            OSSL_PARAM_construct_end()\n        };\n        ctx = EVP_PKEY_CTX_new_from_name(NULL, alg->name, NULL);\n        if (!ctx || EVP_PKEY_keygen_init(ctx) <= 0\n            || EVP_PKEY_CTX_set_params(ctx, params) <= 0\n            || EVP_PKEY_generate(ctx, &key) <= 0) goto done;\n    } else {\n        key = import_key(alg, \"seed\", &seed, EVP_PKEY_KEYPAIR);\n        if (!key) goto done;\n    }\n    if (!(pub_allocated = enif_alloc_binary(alg->public_key, &pub))\n        || !(priv_allocated = enif_alloc_binary(alg->private_key, &priv))) goto done;\n    if (!EVP_PKEY_get_octet_string_param(key, OSSL_PKEY_PARAM_PUB_KEY,\n            pub.data, pub.size, &written) || written != pub.size\n        || !EVP_PKEY_get_octet_string_param(key, OSSL_PKEY_PARAM_PRIV_KEY,\n            priv.data, priv.size, &written) || written != priv.size) goto done;\n    ok = 1;\ndone:\n    EVP_PKEY_free(key);\n    EVP_PKEY_CTX_free(ctx);\n    if (ok) {\n        result = enif_make_tuple2(env, enif_make_binary(env, &pub), enif_make_binary(env, &priv));\n        ERR_clear_error();\n        return result;\n    }\n    if (pub_allocated) enif_release_binary(&pub);\n    if (priv_allocated) { OPENSSL_cleanse(priv.data, priv.size); enif_release_binary(&priv); }\n    return failure(env, \"expand_seed\");\n}\n\n/* FIPS 203 deterministic encapsulation for known-answer tests only. */\nstatic ERL_NIF_TERM encapsulate_test(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {\n    ErlNifBinary pub, randomness, ciphertext = {0}, secret = {0};\n    EVP_PKEY *key = NULL;\n    EVP_PKEY_CTX *ctx = NULL;\n    size_t ciphertext_size = 1088, secret_size = 32;\n    int ciphertext_allocated = 0, secret_allocated = 0, ok = 0;\n    ERL_NIF_TERM result;\n    if (argc != 2 || !enif_inspect_binary(env, argv[0], &pub) || pub.size != 1184\n        || !enif_inspect_binary(env, argv[1], &randomness) || randomness.size != 32)\n        return enif_make_badarg(env);\n    ERR_clear_error();\n    OSSL_PARAM params[] = {\n        OSSL_PARAM_construct_octet_string(OSSL_KEM_PARAM_IKME, randomness.data, randomness.size),\n        OSSL_PARAM_construct_end()\n    };\n    key = import_key(&algorithms[0], OSSL_PKEY_PARAM_PUB_KEY, &pub, EVP_PKEY_PUBLIC_KEY);\n    if (!key || !(ctx = EVP_PKEY_CTX_new_from_pkey(NULL, key, NULL))\n        || EVP_PKEY_encapsulate_init(ctx, params) <= 0) goto done;\n    if (!(ciphertext_allocated = enif_alloc_binary(ciphertext_size, &ciphertext))\n        || !(secret_allocated = enif_alloc_binary(secret_size, &secret))) goto done;\n    if (EVP_PKEY_encapsulate(ctx, ciphertext.data, &ciphertext_size, secret.data, &secret_size) <= 0\n        || ciphertext_size != ciphertext.size || secret_size != secret.size) goto done;\n    ok = 1;\ndone:\n    EVP_PKEY_CTX_free(ctx);\n    EVP_PKEY_free(key);\n    if (ok) {\n        result = enif_make_tuple2(env, enif_make_binary(env, &ciphertext), enif_make_binary(env, &secret));\n        ERR_clear_error();\n        return result;\n    }\n    if (ciphertext_allocated) enif_release_binary(&ciphertext);\n    if (secret_allocated) { OPENSSL_cleanse(secret.data, secret.size); enif_release_binary(&secret); }\n    return failure(env, \"encapsulate_test\");\n}\n\nstatic ERL_NIF_TERM sign_context(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {\n    const Algorithm *alg;\n    ErlNifBinary secret, message, context, signature = {0};\n    EVP_PKEY *key = NULL;\n    EVP_PKEY_CTX *ctx = NULL;\n    EVP_SIGNATURE *scheme = NULL;\n    int deterministic, allocated = 0, ok = 0;\n    size_t length;\n    ERL_NIF_TERM result;\n    if (argc != 5 || !(alg = algorithm(env, argv[0])) || !alg->signature\n        || !enif_inspect_binary(env, argv[1], &secret)\n        || secret.size != (alg == &algorithms[1] ? alg->seed : alg->private_key)\n        || !enif_inspect_binary(env, argv[2], &message)\n        || !enif_inspect_binary(env, argv[3], &context) || context.size > 255)\n        return enif_make_badarg(env);\n    if (enif_is_identical(argv[4], enif_make_atom(env, \"true\"))) deterministic = 1;\n    else if (enif_is_identical(argv[4], enif_make_atom(env, \"false\"))) deterministic = 0;\n    else return enif_make_badarg(env);\n    ERR_clear_error();\n    OSSL_PARAM params[] = {\n        OSSL_PARAM_construct_octet_string(OSSL_SIGNATURE_PARAM_CONTEXT_STRING, context.data, context.size),\n        OSSL_PARAM_construct_int(OSSL_SIGNATURE_PARAM_DETERMINISTIC, &deterministic),\n        OSSL_PARAM_construct_end()\n    };\n    key = import_key(alg, alg == &algorithms[1] ? \"seed\" : OSSL_PKEY_PARAM_PRIV_KEY,\n        &secret, EVP_PKEY_KEYPAIR);\n    if (!key || !(ctx = EVP_PKEY_CTX_new_from_pkey(NULL, key, NULL))\n        || !(scheme = EVP_SIGNATURE_fetch(NULL, alg->name, NULL))\n        || EVP_PKEY_sign_message_init(ctx, scheme, params) <= 0) goto done;\n    length = alg->signature;\n    if (!(allocated = enif_alloc_binary(length, &signature))) goto done;\n    if (EVP_PKEY_sign(ctx, signature.data, &length, message.data, message.size) <= 0\n        || length != signature.size) goto done;\n    ok = 1;\ndone:\n    EVP_SIGNATURE_free(scheme);\n    EVP_PKEY_CTX_free(ctx);\n    EVP_PKEY_free(key);\n    if (ok) {\n        result = enif_make_binary(env, &signature);\n        ERR_clear_error();\n        return result;\n    }\n    if (allocated) enif_release_binary(&signature);\n    return failure(env, \"sign_context\");\n}\n\nstatic ERL_NIF_TERM verify_context(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {\n    const Algorithm *alg;\n    ErlNifBinary pub, message, signature, context;\n    EVP_PKEY *key = NULL;\n    EVP_PKEY_CTX *ctx = NULL;\n    EVP_SIGNATURE *scheme = NULL;\n    int verified = -1;\n    if (argc != 5 || !(alg = algorithm(env, argv[0])) || !alg->signature\n        || !enif_inspect_binary(env, argv[1], &pub)\n        || !enif_inspect_binary(env, argv[2], &message)\n        || !enif_inspect_binary(env, argv[3], &signature)\n        || !enif_inspect_binary(env, argv[4], &context)) return enif_make_badarg(env);\n    if (pub.size != alg->public_key || signature.size != alg->signature || context.size > 255)\n        return enif_make_atom(env, \"false\");\n    ERR_clear_error();\n    OSSL_PARAM params[] = {\n        OSSL_PARAM_construct_octet_string(OSSL_SIGNATURE_PARAM_CONTEXT_STRING, context.data, context.size),\n        OSSL_PARAM_construct_end()\n    };\n    key = import_key(alg, OSSL_PKEY_PARAM_PUB_KEY, &pub, EVP_PKEY_PUBLIC_KEY);\n    if (!key || !(ctx = EVP_PKEY_CTX_new_from_pkey(NULL, key, NULL))\n        || !(scheme = EVP_SIGNATURE_fetch(NULL, alg->name, NULL))\n        || EVP_PKEY_verify_message_init(ctx, scheme, params) <= 0) goto done;\n    verified = EVP_PKEY_verify(ctx, signature.data, signature.size, message.data, message.size);\ndone:\n    EVP_SIGNATURE_free(scheme);\n    EVP_PKEY_CTX_free(ctx);\n    EVP_PKEY_free(key);\n    if (verified < 0) return failure(env, \"verify_context\");\n    ERR_clear_error();\n    return enif_make_atom(env, verified == 1 ? \"true\" : \"false\");\n}\n\nstatic int load(ErlNifEnv *env, void **private_data, ERL_NIF_TERM info) {\n    unsigned int expected;\n    (void)private_data;\n    return !enif_get_uint(env, info, &expected) || expected != OPENSSL_VERSION_MAJOR\n        || OPENSSL_version_major() != expected || OpenSSL_version_num() < 0x30500000L;\n}\n\n/* Cover restores the original Erlang module after instrumentation. The\n * bridge holds no private state or resource types across calls, so each\n * module instance can use the same library after the ordinary ABI check. */\nstatic int upgrade(ErlNifEnv *env, void **private_data, void **old_private_data, ERL_NIF_TERM info) {\n    (void)old_private_data;\n    return load(env, private_data, info);\n}\n\nstatic ErlNifFunc functions[] = {\n    {\"expand\", 2, expand, ERL_NIF_DIRTY_JOB_CPU_BOUND},\n    {\"encapsulate_test\", 2, encapsulate_test, ERL_NIF_DIRTY_JOB_CPU_BOUND},\n    {\"sign_context\", 5, sign_context, ERL_NIF_DIRTY_JOB_CPU_BOUND},\n    {\"verify_context\", 5, verify_context, ERL_NIF_DIRTY_JOB_CPU_BOUND}\n};\nERL_NIF_INIT(lawspec_beam_crypto_native, functions, load, NULL, upgrade, NULL)\n",
                  "build": "#!/usr/bin/env escript\n%%! -noshell\n%% Build once before Rebar/Mix/Gleam compilation; no compiler runs at application\n%% startup. CC names one executable. LAWSPEC_OPENSSL_PREFIX selects a development\n%% installation matching OTP's OpenSSL major version (3.5+).\n%% ref:DEC-typed-core-boundary\n-mode(compile).\n\nmain(Arguments) ->\n    try\n        Project = case Arguments of\n            [] -> filename:dirname(filename:absname(escript:script_name()));\n            [Directory] -> filename:absname(Directory);\n            _ -> fail(\"usage: escript lawspec_crypto_build.escript [project-directory]\")\n        end,\n        build(Project)\n    catch\n        throw:{build_error, Message} -> io:format(standard_error, \"LawSpec crypto: ~ts~n\", [Message]), halt(1);\n        error:Reason -> io:format(standard_error, \"LawSpec crypto build failed: ~tp~n\", [Reason]), halt(1)\n    end.\n\nbuild(Project) ->\n    case list_to_integer(erlang:system_info(otp_release)) >= 29 of\n        true -> ok;\n        false -> fail(\"Erlang/OTP 29 or newer is required\")\n    end,\n    [{<<\"OpenSSL\">>, Version, Description}] = crypto:info_lib(),\n    Major = Version bsr 28,\n    MissingAlgorithms = lists:append([Expected -- crypto:supports(Kind) || {Kind, Expected} <-\n        [{kems, [mlkem768]}, {public_keys, [mldsa65, slh_dsa_shake_128f]},\n         {hashs, [sha3_256, shake256]}, {ciphers, [aes_256_gcm]}]]),\n    case MissingAlgorithms of\n        [] -> ok;\n        Missing -> fail(io_lib:format(\"OTP crypto lacks ~tp; install OTP with OpenSSL 3.5+\", [Missing]))\n    end,\n    Compiler = executable(env(\"CC\", \"cc\")),\n    {Include, Library, ProviderVersion} = openssl(Major),\n    OtpInclude = filename:join([code:root_dir(), \"usr\", \"include\"]),\n    Source = filename:join([Project, \"priv\", \"lawspec_crypto_native.c\"]),\n    Output = filename:join([Project, \"priv\", \"lawspec_crypto_native.so\"]),\n    Stamp = Output ++ \".build\",\n    SourceBytes = read(Source),\n    Args = [\"-std=c11\", \"-O2\", \"-Wall\", \"-Wextra\", \"-Werror\", \"-fPIC\", \"-shared\"] ++\n        platform_flags() ++ [\"-DLAWSPEC_OPENSSL_MAJOR=\" ++ integer_to_list(Major),\n        \"-I\" ++ OtpInclude, \"-I\" ++ Include, Source, \"-L\" ++ Library,\n        \"-Xlinker\", \"-rpath\", \"-Xlinker\", Library, \"-lcrypto\"],\n    Fingerprint = crypto:hash(sha3_256, term_to_binary({SourceBytes,\n        read(escript:script_name()), read(filename:join(Include, \"openssl/opensslv.h\")),\n        read(filename:join(OtpInclude, \"erl_nif.h\")),\n        erlang:system_info(system_architecture), erlang:system_info(nif_version),\n        Version, Description, ProviderVersion, Compiler, Args})),\n    case current(Stamp, Output, Fingerprint) of\n        true -> ok;\n        false ->\n            %% A failed or concurrent build cannot replace a working library.\n            Temporary = Output ++ \".\" ++ os:getpid() ++ \".tmp\",\n            try\n                checked(Compiler, Args ++ [\"-o\", Temporary]),\n                ok = file:rename(Temporary, Output),\n                ok = file:write_file(Stamp, term_to_binary({Fingerprint, crypto:hash(sha3_256, read(Output))})),\n                io:format(\"Built LawSpec crypto bridge (~ts).~n\", [Description])\n            after\n                file:delete(Temporary)\n            end\n    end.\n\nplatform_flags() ->\n    case os:type() of\n        {unix, darwin} -> [\"-undefined\", \"dynamic_lookup\"];\n        {unix, _} -> [];\n        _ -> fail(\"the crypto bridge build requires a Unix C toolchain; use WSL on Windows\")\n    end.\n\nopenssl(Major) ->\n    case os:getenv(\"LAWSPEC_OPENSSL_PREFIX\") of\n        false -> discover_openssl(Major);\n        Prefix -> prefix(Prefix, \"explicit prefix\")\n    end.\n\ndiscover_openssl(Major) ->\n    case os:find_executable(\"pkg-config\") of\n        false -> homebrew_openssl(Major);\n        Pkg ->\n            case run(Pkg, [\"--modversion\", \"libcrypto\"]) of\n                {0, Text} ->\n                    Version = string:trim(binary_to_list(Text)),\n                    case string:prefix(Version, integer_to_list(Major) ++ \".\") of\n                        nomatch -> homebrew_openssl(Major);\n                        _ -> {query(Pkg, [\"--variable=includedir\", \"libcrypto\"]),\n                              query(Pkg, [\"--variable=libdir\", \"libcrypto\"]), Version}\n                    end;\n                _ -> homebrew_openssl(Major)\n            end\n    end.\n\nhomebrew_openssl(Major) ->\n    case os:find_executable(\"brew\") of\n        false -> missing_openssl(Major);\n        Brew ->\n            case run(Brew, [\"--prefix\", \"openssl@\" ++ integer_to_list(Major)]) of\n                {0, Text} -> prefix(string:trim(binary_to_list(Text)), \"Homebrew\");\n                _ -> missing_openssl(Major)\n            end\n    end.\n\nprefix(Prefix, Origin) ->\n    Absolute = filename:absname(Prefix),\n    Include = filename:join(Absolute, \"include\"),\n    case filelib:is_regular(filename:join(Include, \"openssl/evp.h\")) of\n        true ->\n            Libraries = [filename:join(Absolute, Subdir) || Subdir <- [\"lib\", \"lib64\"],\n                lists:any(fun(Name) -> filelib:is_regular(filename:join([Absolute, Subdir, Name])) end,\n                    [\"libcrypto.so\", \"libcrypto.dylib\"])],\n            case Libraries of\n                [Library | _] -> {Include, Library, Origin};\n                [] -> fail(\"OpenSSL shared library missing under \" ++ Absolute)\n            end;\n        false -> fail(\"OpenSSL headers missing under \" ++ Absolute)\n    end.\n\nmissing_openssl(Major) -> fail(io_lib:format(\n    \"install pkg-config and OpenSSL ~B development headers/libraries (3.5+), or set LAWSPEC_OPENSSL_PREFIX to that installation\", [Major])).\n\ncurrent(Stamp, Output, Fingerprint) ->\n    case {file:read_file(Stamp), file:read_file(Output)} of\n        {{ok, StampBytes}, {ok, OutputBytes}} ->\n            try binary_to_term(StampBytes, [safe]) =:= {Fingerprint, crypto:hash(sha3_256, OutputBytes)}\n            catch error:badarg -> false end;\n        _ -> false\n    end.\n\nenv(Key, Default) -> case os:getenv(Key) of false -> Default; Value -> Value end.\nexecutable(Name) -> case os:find_executable(Name) of\n    false -> fail(\"executable not found: \" ++ Name ++ \" (CC must name one compiler executable)\");\n    Path -> Path\nend.\n\nread(Path) -> case file:read_file(Path) of\n    {ok, Bytes} -> Bytes;\n    {error, Reason} -> fail(io_lib:format(\"cannot read ~ts: ~tp\", [Path, Reason]))\nend.\n\nquery(Command, Args) -> string:trim(binary_to_list(checked(Command, Args))).\nchecked(Command, Args) -> case run(Command, Args) of\n    {0, Output} -> Output;\n    {Status, Output} -> fail(io_lib:format(\"~ts exited ~B:~n~ts\", [Command, Status, Output]))\nend.\n\n%% Argument arrays, never a shell: project and installation paths may contain\n%% spaces, quotes, dollar signs or other shell metacharacters.\nrun(Command, Args) ->\n    Port = open_port({spawn_executable, Command}, [binary, exit_status, use_stdio, stderr_to_stdout, {args, Args}]),\n    collect(Port, []).\n\ncollect(Port, Parts) ->\n    receive\n        {Port, {data, Bytes}} -> collect(Port, [Bytes | Parts]);\n        {Port, {exit_status, Status}} -> {Status, iolist_to_binary(lists:reverse(Parts))}\n    end.\n\nfail(Message) -> throw({build_error, lists:flatten(Message)}).\n"
                };
const requireThat = (condition, message) => {
  if (!condition) throw new Error(message);
};
async function exists(file) {
  try { await access(file); return true; } catch { return false; }
}
const includesPath = (root, directories, directory) =>
  directories.some((item) => path.resolve(root, item) === path.resolve(root, directory));

// Hex requirements used by Rebar and Gleam. Only stable numeric releases are
// admitted by the compatibility profiles. Reject unsupported syntax explicitly
// instead of accepting an old compiled dependency after a manifest edit.
export function satisfiesRequirement(version, requirement) {
  const compare = (left, right) => {
    const a = left.split(".").map(Number), b = right.split(".").map(Number);
    for (let i = 0; i < Math.max(a.length, b.length); i++) {
      const difference = (a[i] ?? 0) - (b[i] ?? 0);
      if (difference) return Math.sign(difference);
    }
    return 0;
  };
  requireThat(/^\d+(?:\.\d+)*$/.test(version), `Cannot verify dependency version ${version}`);
  const clauses = String(requirement).trim().split(/\s+or\s+/).map((clause) =>
    clause.split(/\s+and\s+/).map((term) => {
      const match = /^(~>|>=|<=|==|!=|>|<)?\s*(\d+(?:\.\d+)*)$/.exec(term.trim());
      requireThat(match, `Cannot verify Hex requirement ${JSON.stringify(requirement)}; use an exact stable version`);
      const [, operator = "==", wanted] = match;
      const difference = compare(version, wanted);
      if (operator === "~>") {
        const parts = wanted.split(".").map(Number);
        requireThat(parts.length === 2 || parts.length === 3, `Cannot verify Hex requirement ${JSON.stringify(requirement)}`);
        const upper = parts.length === 2 ? `${parts[0] + 1}.0.0` : `${parts[0]}.${parts[1] + 1}.0`;
        return difference >= 0 && compare(version, upper) < 0;
      }
      return {"==": difference === 0, "!=": difference !== 0, ">=": difference >= 0,
        "<=": difference <= 0, ">": difference > 0, "<": difference < 0}[operator];
    }));
  return clauses.some((clause) => clause.every(Boolean));
}

// Native readers evaluate the tools' effective configuration. Their reports go
// to a separate file so compiler warnings cannot be mistaken for JSON.
const erlangProbe = String.raw`#!/usr/bin/env escript
-mode(compile).
main([Input, Output]) ->
    try
        {ok, Bytes} = file:read_file(Input),
        Data = inspect(json:decode(Bytes)),
        ok = file:write_file(Output, json:encode(Data))
    catch
        throw:{doctor, Message} -> io:format(standard_error, "~ts~n", [Message]), halt(1);
        Class:Reason -> io:format(standard_error, "BEAM doctor: ~tp:~tp~n", [Class, Reason]), halt(1)
    end.

inspect(#{<<"mode">> := <<"otp">>}) ->
    Major = erlang:system_info(otp_release),
    {ok, Version} = file:read_file(filename:join([code:root_dir(), "releases", Major, "OTP_VERSION"])),
    #{otp => string:trim(Version)};
inspect(#{<<"mode">> := <<"rebar">>, <<"archive">> := Archive, <<"proper">> := Proper}) ->
    {ok, Parts} = escript:extract(os:find_executable("rebar3"), []),
    {archive, Zip} = lists:keyfind(archive, 1, Parts),
    ArchivePath = text(Archive),
    ok = file:write_file(ArchivePath, Zip),
    {ok, Files} = zip:extract(Zip, [memory]),
    Directories = lists:usort([filename:dirname(Name) || {Name, _} <- Files, filename:extension(Name) =:= ".beam"]),
    [true = code:add_patha(ArchivePath ++ "/" ++ Dir) || Dir <- Directories],
    State = rebar_state:apply_profiles(rebar_state:new(rebar_config:consult_root()), [test]),
    Get = fun(Key, Default) -> rebar_state:get(State, Key, Default) end,
    ProperDependency = lists:any(fun
        ({proper, Version}) when is_list(Version) -> true;
        ({proper, Version, {pkg, proper}}) when is_list(Version) -> true;
        (_) -> false
    end, Get(deps, [])),
    Report = proplists:get_value(report, Get(eunit_opts, [])),
    Reporter = Report =:= {lawspec_beam_report, []} orelse Report =:= lawspec_beam_report,
    #{src_dirs => directories(Get(src_dirs, ["src"])),
      extra_src_dirs => directories(Get(extra_src_dirs, [])),
      reporter => Reporter, proper_dependency => ProperDependency,
      proper_requirement => case lists:keyfind(proper, 1, Get(deps, [])) of
          {proper, Requirement} when is_list(Requirement) -> unicode:characters_to_binary(Requirement);
          {proper, Requirement, {pkg, proper}} when is_list(Requirement) -> unicode:characters_to_binary(Requirement);
          _ -> null
      end,
      filters => Get(eunit_tests, []) =/= [],
      alias => proplists:is_defined(eunit, Get(alias, [])) orelse proplists:is_defined(eunit, Get(aliases, [])),
      crypto_hook => lists:any(fun
          ({compile, Command}) -> string:trim(Command) =:= "escript lawspec_crypto_build.escript";
          (_) -> false
      end, Get(pre_hooks, [])),
      proper => app(proper, text(Proper), proper)};
inspect(#{<<"mode">> := <<"gleam">>, <<"root">> := Root}) ->
    Base = filename:join([text(Root), "build", "dev", "erlang"]),
    maps:from_list([{Name, app(Name, filename:join([Base, atom_to_list(Name), "ebin"]), Module)} ||
        {Name, Module} <- [{gleam_stdlib, gleam@list}, {gleeunit, gleeunit}, {qcheck, qcheck}]]);
inspect(#{<<"mode">> := <<"crypto">>, <<"ebin">> := Ebin}) ->
    true = code:add_patha(text(Ebin)),
    case code:ensure_loaded(lawspec_beam_crypto_native) of
        {module, lawspec_beam_crypto_native} -> ok;
        Other -> fail(io_lib:format("Cannot load the compiled OpenSSL bridge: ~tp", [Other]))
    end,
    [{<<"OpenSSL">>, _, Version}] = crypto:info_lib(),
    #{openssl => Version}.

app(Name, Ebin, Module) ->
    case file:consult(filename:join(Ebin, atom_to_list(Name) ++ ".app")) of
        {ok, [{application, Name, Properties}]} ->
            true = code:add_patha(Ebin),
            case code:ensure_loaded(Module) of
                {module, Module} ->
                    Expected = filename:absname(filename:join(Ebin, atom_to_list(Module) ++ ".beam")),
                    case filename:absname(code:which(Module)) =:= Expected of
                        true -> unicode:characters_to_binary(proplists:get_value(vsn, Properties));
                        false -> fail(io_lib:format("~p is shadowed by another installed module", [Name]))
                    end;
                _ -> fail(io_lib:format("~p is not compiled; build the project's test dependencies first", [Name]))
            end;
        _ -> fail(io_lib:format("~p is not installed and compiled; build the project's test dependencies first", [Name]))
    end.
directories(Items) -> [unicode:characters_to_binary(case Item of {Dir, _} -> Dir; Dir -> Dir end) || Item <- Items].
text(Value) -> unicode:characters_to_list(Value).
fail(Message) -> throw({doctor, lists:flatten(Message)}).
`;

const elixirProbe = String.raw`
[input, output] = System.argv()
request = input |> File.read!() |> :json.decode()
config = Mix.Project.config()
dependency = Enum.find(Mix.Dep.load_and_cache(), &(&1.app == :stream_data))
unless dependency && dependency.scm == Hex.SCM && dependency.top_level do
  Mix.raise("StreamData must be a direct Hex test dependency, without a path or Git replacement")
end
unless match?({:ok, _}, dependency.status) && Code.ensure_loaded?(StreamData) do
  Mix.raise("StreamData is not installed and compiled; run MIX_ENV=test mix deps.compile")
end
loaded = :code.which(StreamData) |> List.to_string() |> Path.expand()
expected = Path.join([dependency.opts[:build], "ebin", "Elixir.StreamData.beam"]) |> Path.expand()
unless loaded == expected, do: Mix.raise("StreamData is shadowed by another installed module")
version = Application.spec(:stream_data, :vsn) |> to_string()
unless dependency.status == {:ok, version}, do: Mix.raise("StreamData's compiled version differs from the resolved dependency")

# Inspect test_helper configuration without asking ExUnit to execute a suite.
# Stage the real formatter because generation may not have written it yet.
Code.compiler_options(ignore_module_conflict: true, no_warn_undefined: :all)
Code.compile_file(request["formatter"])
ExUnit.start(autorun: false)
helper = Path.join(request["test_dir"], "test_helper.exs")
unless File.regular?(helper), do: Mix.raise("Missing #{helper}; configure the LawSpec ExUnit formatter there")
Code.require_file(helper)
ExUnit.configure(autorun: false)
settings = ExUnit.configuration()
compilers = Keyword.get(config, :compilers, Mix.compilers())
coverage = Keyword.get(config, :test_coverage, [])
data = %{
  elixir: System.version(), stream_data: version,
  erlc_paths: Keyword.get(config, :erlc_paths, ["src"]),
  elixirc_paths: Keyword.get(config, :elixirc_paths, ["lib"]),
  test_paths: Keyword.get(config, :test_paths, ["test"]),
  test_pattern: Keyword.get(config, :test_pattern, "*_test.exs"),
  ignored: Keyword.get(config, :test_ignore_filters, []) != [],
  alias: Enum.any?([:test, :"compile.erlang", :"compile.elixir"], &Keyword.has_key?(config[:aliases] || [], &1)),
  compilers: Enum.map(compilers, &to_string/1),
  reporter: LawSpec.Beam.ExUnitFormatter in settings[:formatters],
  filtered: settings[:exclude] != [] or settings[:include] != [],
  dry_run: settings[:dry_run], max_failures: to_string(settings[:max_failures]),
  crypto_compiler: :lawspec_crypto in compilers and Code.ensure_loaded?(Mix.Tasks.Compile.LawspecCrypto),
  coverage: %{output: Path.expand(Keyword.get(coverage, :output, "cover")),
    tool: inspect(Keyword.get(coverage, :tool, Mix.Tasks.Test.Coverage)),
    compilePath: Path.expand(Mix.Project.compile_path())}
}
File.write!(output, :json.encode(data))
`;

export async function beamDoctor(target, root, artifacts, run) {
  root = path.resolve(root);
  const temporary = await mkdtemp(path.join(os.tmpdir(), "lawspec-beam-doctor-"));
  const sourceDir = target.sourceDir ?? (target.language === "elixir" ? "lib" : "src");
  const testDir = target.testDir ?? "test";
  const needsCrypto = artifacts.length
    ? artifacts.some((file) => file.path === "priv/lawspec_crypto_native.c")
    : await exists(path.join(root, "priv/lawspec_crypto_native.c"));
  try {
    const probeFile = path.join(temporary, "probe.escript");
    const input = path.join(temporary, "input.json");
    const output = path.join(temporary, "output.json");
    await writeFile(probeFile, erlangProbe);
    const probe = async (mode, options = {}) => {
      await writeFile(input, JSON.stringify({mode, ...options}));
      await rm(output, {force: true});
      await run("escript", [probeFile, input, output], root);
      return JSON.parse(await readFile(output, "utf8"));
    };
    // Fail clearly before using OTP's JSON API on an older VM.
    const otp = (await run("erl", ["-noshell", "-eval", 'io:put_chars(erlang:system_info(otp_release)), halt().'], root)).trim();
    requireThat(otp === "29", `BEAM targets require the verified Erlang/OTP 29 profile; found ${otp}`);
    const versions = await probe("otp");
    let coverage;

    if (target.language === "erlang") {
      const version = await run("rebar3", ["version"], root);
      versions.rebar3 = /\brebar (\S+)/.exec(version)?.[1];
      const proper = (await run("rebar3", ["as", "test", "path", "--app", "proper", "--ebin"], root)).trim();
      requireThat(proper && !proper.includes("\n"), "Cannot resolve PropEr; run rebar3 as test compile first");
      requireThat(!await exists(path.join(root, "_checkouts/proper")), "PropEr must resolve from Hex without a checkout replacement");
      const data = await probe("rebar", {archive: path.join(temporary, "rebar.ez"), proper});
      requireThat(data.proper_dependency, "PropEr must be a direct Hex dependency in the Rebar test profile");
      requireThat(satisfiesRequirement(data.proper, data.proper_requirement),
        "PropEr's compiled version does not satisfy the test profile dependency; run rebar3 as test compile");
      requireThat(includesPath(root, data.src_dirs, sourceDir), "Rebar src_dirs must include the configured sourceDir");
      requireThat(path.resolve(root, testDir) === path.join(root, "test") || includesPath(root, data.extra_src_dirs, testDir),
        "Rebar extra_src_dirs must include the configured testDir when it is not test");
      requireThat(data.reporter, "Configure Rebar eunit_opts with {report, {lawspec_beam_report, []}} for native execution reports");
      requireThat(!data.filters && !data.alias, "Rebar must use unfiltered EUnit discovery without eunit_tests or an eunit alias");
      requireThat(!needsCrypto || data.crypto_hook, "Add the compile pre_hook: escript lawspec_crypto_build.escript");
      versions.proper = data.proper;
    } else if (target.language === "elixir") {
      const formatter = path.join(temporary, "formatter.ex");
      const mixProbe = path.join(temporary, "probe.exs");
      await writeFile(formatter, runtime.formatter);
      await writeFile(mixProbe, elixirProbe);
      await writeFile(input, JSON.stringify({formatter, test_dir: testDir}));
      await rm(output, {force: true});
      await run("mix", ["run", "--no-compile", "--no-start", "--no-deps-check", mixProbe, input, output], root,
        {env: {...process.env, MIX_ENV: "test", ...(process.env.LAWSPEC_OFFLINE === "1" ? {HEX_OFFLINE: "1"} : {})}});
      const data = JSON.parse(await readFile(output, "utf8"));
      for (const [key, directory] of [["erlc_paths", target.sourceDir ?? "src"], ["elixirc_paths", sourceDir],
        ["erlc_paths", `${testDir}/support`], ["elixirc_paths", `${testDir}/support`], ["test_paths", testDir]])
        requireThat(includesPath(root, data[key], directory), `Mix ${key} must include ${directory} in MIX_ENV=test`);
      requireThat(data.compilers.includes("erlang") && data.compilers.includes("elixir"), "Mix must enable both erlang and elixir compilers");
      requireThat(!data.alias && !data.ignored && data.test_pattern === "*_test.exs",
        "Mix must discover *_test.exs without test_ignore_filters or aliases for test/compile.erlang/compile.elixir");
      requireThat(data.reporter, "Configure LawSpec.Beam.ExUnitFormatter in test_helper.exs for native execution reports");
      requireThat(!data.filtered && !data.dry_run,
        "ExUnit must run without include/exclude filters or dry_run");
      requireThat(data.max_failures === "infinity" ||
        typeof data.max_failures === "string" && /^[1-9][0-9]*$/.test(data.max_failures),
        "ExUnit max_failures must be a positive integer or :infinity");
      requireThat(!needsCrypto || data.crypto_compiler, "Add :lawspec_crypto to Mix compilers and define Mix.Tasks.Compile.LawspecCrypto to run the bridge builder");
      Object.assign(versions, {elixir: data.elixir, stream_data: data.stream_data});
      coverage = data.coverage;
    } else {
      requireThat(sourceDir === "src" && testDir === "test", "Gleam requires sourceDir=src and testDir=test; choose a separate project root for another layout");
      versions.gleam = /\bgleam (\S+)/.exec(await run("gleam", ["--version"], root))?.[1];
      const configFile = path.join(temporary, "gleam.json");
      await run("gleam", ["export", "package-information", "--out", configFile], root);
      const config = JSON.parse(await readFile(configFile, "utf8"))["gleam.toml"];
      requireThat(config?.target === "erlang", "gleam.toml must select target=erlang");
      requireThat(config.dependencies?.gleam_stdlib?.version &&
        ["gleeunit", "qcheck"].every((name) => config.dev_dependencies?.[name]?.version),
        "Gleam requires Hex gleam_stdlib plus direct gleeunit and qcheck dev-dependencies, without local replacements");
      requireThat(path.resolve(root, config.dev_dependencies?.lawspec_test_support?.path ?? "") === path.join(root, "test-support"),
        "Add lawspec_test_support = { path = \"./test-support\" } to Gleam dev-dependencies");
      await run("gleam", ["export", "package-information", "--out", configFile], path.join(root, "test-support"));
      const support = JSON.parse(await readFile(configFile, "utf8"))["gleam.toml"];
      requireThat(support?.name === "lawspec_test_support" && support.target === "erlang" && support.dependencies?.qcheck?.version,
        "test-support/gleam.toml must define lawspec_test_support for Erlang with a Hex qcheck dependency");
      const runnerPath = path.join(root, "test", `${config.name}_test.gleam`);
      const runner = (await readFile(runnerPath, "utf8")).replace(/\/\/[^\n]*/g, "").trim();
      requireThat(/^@external\(\s*erlang\s*,\s*"lawspec_beam_test_run"\s*,\s*"gleam_main"\s*\)\s*pub\s+fn\s+main\(\s*\)\s*->\s*Nil\s*$/.test(runner),
        `Use @external(erlang, "lawspec_beam_test_run", "gleam_main") pub fn main() -> Nil in test/${config.name}_test.gleam; put tests in other *_test.gleam modules`);
      const resolved = new Map((await run("gleam", ["deps", "list"], root)).trim().split("\n")
        .map((line) => line.trim().split(/\s+/)));
      const compiled = await probe("gleam", {root});
      for (const name of ["gleam_stdlib", "gleeunit", "qcheck"]) {
        requireThat(resolved.get(name) === compiled[name], `${name}'s compiled version differs from the resolved dependency; run gleam build`);
        const requirement = (config.dependencies?.[name] ?? config.dev_dependencies?.[name]).version;
        requireThat(satisfiesRequirement(compiled[name], requirement), `${name}'s compiled version does not satisfy gleam.toml; run gleam build`);
        versions[name] = compiled[name];
      }
      requireThat(satisfiesRequirement(versions.qcheck, support.dependencies.qcheck.version),
        "qcheck's compiled version does not satisfy test-support/gleam.toml; run gleam build");
    }

    if (needsCrypto) {
      // An ebin directory under an application named "crypto" would shadow
      // OTP's crypto priv directory in the code server, even without an .app.
      const project = path.join(temporary, "lawspec_doctor_native");
      const ebin = path.join(project, "ebin");
      await mkdir(path.join(project, "priv"), {recursive: true});
      await mkdir(ebin);
      const builder = path.join(project, "lawspec_crypto_build.escript");
      const native = path.join(project, "lawspec_beam_crypto_native.erl");
      await writeFile(builder, runtime.build);
      await writeFile(native, runtime.native);
      await writeFile(path.join(project, "priv/lawspec_crypto_native.c"), runtime.c);
      await run("escript", [builder, project], root);
      await run("erlc", ["-o", ebin, native], root);
      // Loading the real NIF checks the shared-library ABI as well as compilation.
      Object.assign(versions, await probe("crypto", {ebin}));
    }
    return {versions, ...(coverage ? {coverage} : {})};
  } finally {
    await rm(temporary, {recursive: true, force: true});
  }
}
