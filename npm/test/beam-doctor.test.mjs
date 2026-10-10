// Generated from templates/npm/test/beam-doctor.test.mjs by lawspec-dev generate. Do not edit.
import {test} from "node:test";
import assert from "node:assert/strict";
import {access, mkdir, mkdtemp, readFile, readdir, rm, writeFile} from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import {beamDoctor, satisfiesRequirement} from "../beam-doctor.mjs";
import {supported} from "../doctor.mjs";

const rebar = () => ({src_dirs: ["src"], extra_src_dirs: [], reporter: true,
  proper_dependency: true, proper_requirement: "1.5.0", filters: false, alias: false, crypto_hook: false, proper: "1.5.0"});
const mix = () => ({elixir: "1.20.4", stream_data: "1.4.0", erlc_paths: ["src", "test/support"],
  elixirc_paths: ["lib", "test/support"], test_paths: ["test"], test_pattern: "*_test.exs",
  ignored: false, alias: false, compilers: ["erlang", "elixir"], reporter: true,
  filtered: false, dry_run: false, max_failures: "infinity", crypto_compiler: false,
  coverage: {output: "/tmp/coverage output", tool: "Mix.Tasks.Test.Coverage", compilePath: "/tmp/build/ebin"}});
const gleam = () => ({name: "example", target: "erlang", dependencies: {gleam_stdlib: {version: "== 1.0.5"}},
  dev_dependencies: {gleeunit: {version: "== 1.11.0"}, qcheck: {version: "== 1.0.5"},
    lawspec_test_support: {path: "./test-support"}}});
const support = () => ({name: "lawspec_test_support", target: "erlang", dependencies: {qcheck: {version: "== 1.0.5"}}});
const compiled = () => ({gleam_stdlib: "1.0.5", gleeunit: "1.11.0", qcheck: "1.0.5"});

// Native tool execution is covered separately by the target integration gates.
// These probes exercise orchestration and diagnostics without installed tools.
async function fixture(t) {
  const root = await mkdtemp(path.join(os.tmpdir(), "lawspec-beam-doctor-test-"));
  t.after(() => rm(root, {recursive: true, force: true}));
  await mkdir(path.join(root, "test"));
  await mkdir(path.join(root, "test-support"));
  await writeFile(path.join(root, "test/example_test.gleam"),
    '@external(erlang, "lawspec_beam_test_run", "gleam_main")\npub fn main() -> Nil\n');
  const state = {root, otp: "29", rebar: rebar(), mix: mix(), gleam: gleam(), support: support(), compiled: compiled(), calls: [], temporary: new Set()};
  const run = async (command, args, cwd, options) => {
    state.calls.push({command, args, cwd, options});
    if (command === "erl") return state.otp;
    if (command === "rebar3") return args[0] === "version" ? "rebar 3.27.1 on Erlang/OTP 29" : path.join(root, "_build/test/lib/proper/ebin");
    if (command === "escript" && args.length === 3) {
      const [script, input, output] = args;
      const request = JSON.parse(await readFile(input, "utf8"));
      state.temporary.add(path.dirname(script));
      const reports = {otp: {otp: "29.1.1"}, rebar: state.rebar, gleam: state.compiled, crypto: {openssl: "OpenSSL 4.0.2"}};
      assert.ok(reports[request.mode]);
      await writeFile(output, JSON.stringify(reports[request.mode]));
    } else if (command === "mix") {
      assert.deepEqual(args.slice(0, 4), ["run", "--no-compile", "--no-start", "--no-deps-check"]);
      assert.equal(options.env.MIX_ENV, "test");
      const request = JSON.parse(await readFile(args.at(-2), "utf8"));
      assert.match(await readFile(request.formatter, "utf8"), /defmodule LawSpec.Beam.ExUnitFormatter/);
      await writeFile(args.at(-1), JSON.stringify(state.mix));
    } else if (command === "gleam") {
      if (args[0] === "--version") return "gleam 1.19.0";
      if (args[0] === "deps") return "Package Version\ngleam_stdlib 1.0.5\ngleeunit 1.11.0\nqcheck 1.0.5\n";
      assert.deepEqual(args.slice(0, 3), ["export", "package-information", "--out"]);
      await writeFile(args[3], JSON.stringify({"gleam.toml": cwd === root ? state.gleam : state.support}));
    } else if (command === "escript") {
      assert.equal(args.length, 2);
      assert.ok(!args[1].startsWith(root + path.sep));
      assert.equal(path.basename(args[1]), "lawspec_doctor_native");
      assert.match(await readFile(args[0], "utf8"), /MissingAlgorithms/);
      assert.match(await readFile(path.join(args[1], "priv/lawspec_crypto_native.c"), "utf8"), /ERL_NIF_INIT/);
      if (state.cryptoError) throw new Error(state.cryptoError);
    } else if (command === "erlc") {
      assert.match(await readFile(args.at(-1), "utf8"), /erlang:load_nif/);
    } else assert.fail(`Unexpected native command: ${command}`);
    return "";
  };
  state.check = (language, options = {}, artifacts = []) => beamDoctor({language, ...options}, root, artifacts, run);
  state.cleaned = async () => {
    for (const directory of state.temporary) await assert.rejects(access(directory));
  };
  return state;
}

test("BEAM profiles reject missing, prerelease and unverified versions", () => {
  for (const language of ["erlang", "elixir", "gleam"]) {
    assert.equal(supported(language, "otp", "29.1.1"), true);
    for (const version of ["28.4", "30", "29.0-rc1", undefined]) assert.equal(supported(language, "otp", version), false);
  }
  for (const [target, dependency, good, bad] of [
    ["erlang", "proper", "1.5.0", "1.5.1"], ["erlang", "rebar3", "3.27.1", "3.28"],
    ["elixir", "elixir", "1.20.4", "1.21"], ["elixir", "stream_data", "1.4.0", "1.3.0"],
    ["gleam", "gleam", "1.18.1", "1.20"], ["gleam", "qcheck", "1.0.5", "1.0.4"],
    ["gleam", "gleam_stdlib", "1.0.5", "1.0.6"], ["gleam", "gleeunit", "1.11.0", "1.10.0"],
  ]) {
    assert.equal(supported(target, dependency, good), true);
    assert.equal(supported(target, dependency, bad), false);
  }
});

test("Hex constraints cannot silently accept stale compiled dependencies", () => {
  for (const [version, requirement, expected] of [
    ["1.5.0", "1.5.0", true], ["1.5.0", "== 1.4.0", false], ["1.5.0", "~> 1.4", true],
    ["1.5.0", "~> 1.4.0", false], ["1.5.0", ">= 1.4.0 and < 2.0.0", true],
    ["1.5.0", "< 1.4.0 or >= 1.5.0 and < 2.0.0", true], ["2.0.0", "~> 1.4", false],
    ["1.5.0", "!= 1.5.0", false], ["1.5.0", "> 1.5.0", false], ["1.5.0", "<= 1.5.0", true],
  ]) assert.equal(satisfiesRequirement(version, requirement), expected);
  for (const requirement of ["*", "~> 1", "1.5.0 or anything", "1.5.0-rc1", ""])
    assert.throws(() => satisfiesRequirement("1.5.0", requirement), /Cannot verify/);
});

test("BEAM preflight uses native readers without running tests or installing dependencies", async t => {
  const f = await fixture(t);
  const before = await readdir(f.root, {recursive: true});
  assert.equal((await f.check("erlang")).versions.proper, "1.5.0");
  const elixir = await f.check("elixir");
  assert.equal(elixir.versions.stream_data, "1.4.0");
  assert.deepEqual(elixir.coverage, mix().coverage);
  assert.equal((await f.check("gleam")).versions.qcheck, "1.0.5");
  assert.deepEqual(await readdir(f.root, {recursive: true}), before);
  assert.ok(f.calls.every(({args}) => !["deps.get", "eunit", "test", "build", "compile", "download"].includes(args[0])));
  assert.ok(!f.calls.some(({command}) => command === "erlc"));
  await f.cleaned();
});

test("Rebar preflight checks the effective test profile, roots and reporter", async t => {
  const f = await fixture(t);
  for (const [change, message] of [
    [{proper_dependency: false}, /direct Hex dependency/], [{src_dirs: ["other"]}, /src_dirs/],
    [{proper_requirement: "1.4.0"}, /compiled version does not satisfy/],
    [{reporter: false}, /eunit_opts/], [{filters: true}, /unfiltered/], [{alias: true}, /unfiltered/],
  ]) {
    f.rebar = {...rebar(), ...change};
    await assert.rejects(f.check("erlang"), message);
  }
  f.rebar = rebar();
  await assert.rejects(f.check("erlang", {testDir: "checks"}), /extra_src_dirs/);
  f.rebar = {...rebar(), src_dirs: ["./source"], extra_src_dirs: ["checks"]};
  await f.check("erlang", {sourceDir: "source", testDir: "checks"});
  await mkdir(path.join(f.root, "_checkouts/proper"), {recursive: true});
  await assert.rejects(f.check("erlang"), /checkout replacement/);
  await f.cleaned();
});

test("Mix preflight checks both compilers, test support and effective ExUnit settings", async t => {
  const f = await fixture(t);
  for (const [change, message] of [
    [{erlc_paths: ["src"]}, /test\/support/], [{elixirc_paths: ["test/support"]}, /lib/],
    [{test_paths: ["checks"]}, /test_paths/], [{compilers: ["elixir"]}, /both erlang and elixir/],
    [{test_pattern: "custom.exs"}, /discover/], [{ignored: true}, /discover/], [{alias: true}, /discover/],
    [{reporter: false}, /ExUnitFormatter/], [{filtered: true}, /filters/],
    [{dry_run: true}, /dry_run/],
  ]) {
    f.mix = {...mix(), ...change};
    await assert.rejects(f.check("elixir"), message);
  }
  f.mix = {...mix(), erlc_paths: ["source", "checks/support"], elixirc_paths: ["source", "checks/support"], test_paths: ["checks"]};
  await f.check("elixir", {sourceDir: "source", testDir: "checks"});
  await f.cleaned();
});

test("Mix preflight accepts native fail-fast limits and rejects invalid limits", async t => {
  const f = await fixture(t);
  for (const max_failures of ["infinity", "1", "2", "1000"]) {
    f.mix = {...mix(), max_failures};
    await f.check("elixir");
  }
  for (const max_failures of ["0", "-1", "1.5", "true", "", undefined]) {
    f.mix = {...mix(), max_failures};
    await assert.rejects(f.check("elixir"), /max_failures must be a positive integer or :infinity/);
  }
  await f.cleaned();
});

test("Gleam preflight requires native discovery and matching resolved/compiled dependencies", async t => {
  const f = await fixture(t);
  await assert.rejects(f.check("gleam", {testDir: "checks"}), /sourceDir=src/);
  f.gleam.target = "javascript";
  await assert.rejects(f.check("gleam"), /target=erlang/);
  f.gleam = gleam();
  f.gleam.dev_dependencies.qcheck = {path: "../qcheck"};
  await assert.rejects(f.check("gleam"), /without local replacements/);
  f.gleam = gleam();
  f.gleam.dev_dependencies.lawspec_test_support.path = "../support";
  await assert.rejects(f.check("gleam"), /test-support/);
  f.gleam = gleam();
  f.support.name = "other";
  await assert.rejects(f.check("gleam"), /must define lawspec_test_support/);
  f.support = support();
  f.compiled.qcheck = "1.0.4";
  await assert.rejects(f.check("gleam"), /compiled version differs/);
  f.compiled = compiled();
  f.gleam.dev_dependencies.qcheck.version = "== 1.0.4";
  await assert.rejects(f.check("gleam"), /does not satisfy gleam.toml/);
  f.gleam = gleam();
  f.support.dependencies.qcheck.version = "== 1.0.4";
  await assert.rejects(f.check("gleam"), /does not satisfy test-support/);
  f.support = support();
  await writeFile(path.join(f.root, "test/example_test.gleam"),
    '// @external(erlang, "lawspec_beam_test_run", "gleam_main")\nimport gleeunit\npub fn main() { gleeunit.main() }\n');
  await assert.rejects(f.check("gleam"), /lawspec_beam_test_run/);
  await f.cleaned();
});

test("crypto preflight builds and loads the real bridge only in a temporary project", async t => {
  const f = await fixture(t);
  const crypto = [{path: "priv/lawspec_crypto_native.c"}];
  await assert.rejects(f.check("erlang", {}, crypto), /compile pre_hook/);
  await assert.rejects(f.check("elixir", {}, crypto), /:lawspec_crypto/);
  f.rebar.crypto_hook = true;
  const before = await readdir(f.root, {recursive: true});
  assert.match((await f.check("erlang", {}, crypto)).versions.openssl, /OpenSSL 4/);
  assert.ok(f.calls.some(({command}) => command === "erlc"));
  assert.deepEqual(await readdir(f.root, {recursive: true}), before);
  f.cryptoError = "OpenSSL headers missing";
  await assert.rejects(f.check("gleam", {}, crypto), /OpenSSL headers missing/);
  await f.cleaned();
});

test("BEAM preflight diagnoses unsupported OTP before using newer APIs", async t => {
  const f = await fixture(t);
  f.otp = "28";
  await assert.rejects(f.check("erlang"), /OTP 29 profile; found 28/);
  assert.equal(f.calls.length, 1);
});
