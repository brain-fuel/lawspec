import { access, mkdir, mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import os from "node:os";
import path from "node:path";

// These are the same sources the compiler emits, including the NIF loader.
const runtime = /*@ beam-doctor-runtime @*/;
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
