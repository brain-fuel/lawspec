// Generated from templates/npm/beam-coverage.mjs by lawspec-dev generate. Do not edit.
import {execFile} from "node:child_process";
import {createHash} from "node:crypto";
import {mkdir, mkdtemp, readFile, readdir, rm, stat, writeFile} from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import {promisify} from "node:util";

const exec = promisify(execFile);
export function beamCoverageRequirement(target, report) {
  if (target.language === "gleam" && Number(report?.versions?.gleam?.split(".")[1] ?? 0) < 19)
    return {tool: "Gleam 1.19 for source coverage", install: "upgrade Gleam to 1.19 so native counters refer to the original source lines"};
  if (target.language === "elixir" && report?.coverage?.tool !== "Mix.Tasks.Test.Coverage")
    return {tool: "Mix.Tasks.Test.Coverage", install: "set test_coverage[:tool] to Mix.Tasks.Test.Coverage in mix.exs"};
  return null;
}

const collector = String.raw`#!/usr/bin/env escript
-mode(compile).
main([Input, Output]) ->
    try
        {ok, Bytes} = file:read_file(Input),
        #{<<"runs">> := Runs, <<"directory">> := Directory} = json:decode(Bytes),
        {ok, _} = cover:start(),
        [ok = cover:import(text(maps:get(<<"file">>, Run))) || Run <- Runs],
        Beams = lists:foldl(fun(Run, Acc) -> maps:merge(Acc, maps:get(<<"beams">>, Run, #{})) end, #{}, Runs),
        Modules = [analyse(Module, text(Directory), Beams) || Module <- lists:sort(cover:imported_modules())],
        true = Modules =/= [],
        ok = file:write_file(Output, json:encode(Modules)),
        cover:stop()
    catch Class:Reason:Stack ->
        io:format(standard_error, "Cannot collect BEAM coverage: ~tp:~tp~n~tp~n", [Class, Reason, Stack]), halt(1)
    end.

analyse(Module, Directory, Beams) ->
    {ok, Calls} = cover:analyse(Module, calls, line),
    Lines = lists:foldl(fun
        ({{_, Line}, Hits}, Acc) when Line > 0 -> maps:update_with(Line, fun(N) -> N + Hits end, Hits, Acc);
        (_, Acc) -> Acc
    end, #{}, Calls),
    Name = atom_to_binary(Module),
    Rows = [#{line => Line, hits => Hits} || {Line, Hits} <- lists:sort(maps:to_list(Lines))],
    case maps:find(Name, Beams) of
        {ok, Beam} -> #{name => Name, lines => Rows, source => source(Module, text(Beam))};
        error ->
            File = binary_to_list(binary:encode_hex(crypto:hash(sha256, Name), lowercase)) ++ ".html",
            {ok, _} = cover:analyse_to_file(Module, [html, {outfile, filename:join(Directory, File)}]),
            #{name => Name, lines => Rows, report => unicode:characters_to_binary(File)}
    end.

source(Module, Beam) ->
    {ok, {Module, [{compile_info, Info}]}} = beam_lib:chunks(Beam, [compile_info]),
    Source = case proplists:get_value(source, Info) of
        undefined ->
            {ok, {Module, [{abstract_code, {raw_abstract_v1, Forms}}]}} = beam_lib:chunks(Beam, [abstract_code]),
            [File | _] = [F || {attribute, _, file, {F, _}} <- Forms], File;
        File -> File
    end,
    unicode:characters_to_binary(Source).
text(Value) -> unicode:characters_to_list(Value).
`;

const escape = (value) => String(value).replace(/[&<>"']/g, (c) =>
  ({"&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;"}[c]));
const totals = (lines) => ({covered: lines.filter(({hits}) => hits > 0).length, total: lines.length});
const percentage = ({covered, total}) => total ? `${(100 * covered / total).toFixed(1)}%` : "no executable lines";
const page = (title, body) => `<!doctype html><html lang="en"><meta charset="utf-8"><title>${escape(title)}</title>
<style>body{font:16px system-ui;margin:2rem;color:#222}table{border-collapse:collapse;width:100%}td,th{padding:.3rem .7rem;text-align:left;border-bottom:1px solid #ddd}pre{margin:0;tab-size:4}.hit{background:#e4f5e9}.miss{background:#ffe6e6}.line,.count{width:4rem;text-align:right;color:#555}a{color:#174da8}</style>
<h1>${escape(title)}</h1>${body}</html>\n`;

// Only exports explicitly returned by this run's invocations are imported.
// A missing export is an error even if the native runner exited successfully.
export async function collectBeamCoverage({root, directory, runs}) {
  if (!runs.length) return null;
  root = path.resolve(root);
  directory = path.resolve(directory);
  const temporary = await mkdtemp(path.join(os.tmpdir(), "lawspec-beam-coverage-"));
  try {
    const inputs = [];
    const seen = new Set();
    let rebarDirectories;
    for (const run of runs) {
      if (!run.run || seen.has(run.run) || path.basename(run.file) !== `${run.run}.coverdata`)
        throw new Error("Invalid or duplicate BEAM coverage invocation");
      seen.add(run.run);
      const info = await stat(run.file).catch(() => null);
      if (!info?.isFile() || !info.size) throw new Error(`Native runner did not export coverage for ${run.run}: ${run.file}`);
      let beams;
      if (run.tool === "rebar3" && !rebarDirectories) {
        // Before the first compile Rebar only knows dependency ebin paths.
        // Ask after the test run so fresh and relocated applications are found.
        const result = await exec("rebar3", ["as", "test", "path", "--ebin", "--separator", "\n"], {cwd: root});
        rebarDirectories = result.stdout.trim().split("\n").filter(Boolean);
        if (!rebarDirectories.length || !rebarDirectories.every((item) => path.isAbsolute(item)))
          throw new Error("Cannot resolve Rebar's application beam directories after coverage");
      }
      const directories = run.tool === "rebar3" ? rebarDirectories
        : run.beamDirectories ?? (run.beamDirectory ? [run.beamDirectory] : []);
      for (const directory of directories) {
        const entries = (await readdir(directory)).filter((name) => name.endsWith(".beam"));
        beams = {...beams, ...Object.fromEntries(entries.map((name) => [name.slice(0, -5), path.resolve(directory, name)]))};
      }
      if (run.metadata) {
        const metadata = JSON.parse(await readFile(run.metadata, "utf8"));
        if (metadata.run !== run.run || metadata.file !== run.file || !metadata.modules?.length)
          throw new Error(`Gleam coverage metadata does not match invocation ${run.run}`);
        beams = Object.fromEntries(metadata.modules.map(({name, beam}) => [name, beam]));
      }
      inputs.push({file: path.resolve(run.file), ...(beams ? {beams} : {})});
    }
    // Assemble all pages off to the side. A failed import or source mapping
    // cannot leave an apparently complete index behind.
    const pages = path.join(temporary, "modules");
    await mkdir(pages);
    const input = path.join(temporary, "input.json"), output = path.join(temporary, "output.json");
    const script = path.join(temporary, "collect.escript");
    await writeFile(script, collector);
    await writeFile(input, JSON.stringify({runs: inputs, directory: pages}));
    await exec("escript", [script, input, output], {cwd: root, maxBuffer: 8 * 1024 * 1024});
    const modules = JSON.parse(await readFile(output, "utf8"));
    for (const module of modules) {
      module.summary = totals(module.lines);
      if (!module.source) continue;
      let source = path.resolve(root, module.source);
      const text = await readFile(source, "utf8");
      // Gleam copies foreign Erlang sources into its build tree. Prefer the
      // original when it is byte-for-byte the source that was compiled.
      const marker = `${path.sep}_gleam_artefacts${path.sep}`;
      if (source.includes(marker)) {
        const original = path.join(root, "src", source.split(marker).at(-1));
        if (await readFile(original, "utf8").catch(() => null) === text) source = original;
      }
      module.source = path.relative(root, source);
      const sourceLines = text.split(/\r?\n/);
      if (module.lines.some(({line}) => line > sourceLines.length))
        throw new Error(`Coverage lines do not match source ${module.source}`);
      const hits = new Map(module.lines.map(({line, hits}) => [line, hits]));
      module.report = createHash("sha256").update(module.name).digest("hex") + ".html";
      const rows = sourceLines.map((line, index) => {
        const count = hits.get(index + 1);
        return `<tr class="${count === undefined ? "" : count ? "hit" : "miss"}" id="L${index + 1}"><td class="line">${index + 1}</td><td class="count">${count ?? ""}</td><td><pre>${escape(line)}</pre></td></tr>`;
      }).join("\n");
      await writeFile(path.join(pages, module.report), page(module.name,
        `<p>${escape(module.source)} — ${percentage(module.summary)}</p><table>${rows}</table>`));
    }
    const summary = modules.reduce((sum, module) => ({covered: sum.covered + module.summary.covered,
      total: sum.total + module.summary.total}), {covered: 0, total: 0});
    const result = {version: 1, root, runs: runs.map(({run}) => run), summary, modules};
    const rows = modules.map((module) => `<tr><td><a href="modules/${module.report}">${escape(module.name)}</a></td><td>${module.summary.covered}/${module.summary.total}</td><td>${percentage(module.summary)}</td></tr>`).join("\n");
    await mkdir(path.join(directory, "modules"), {recursive: true});
    for (const module of modules)
      await writeFile(path.join(directory, "modules", module.report), await readFile(path.join(pages, module.report)));
    await writeFile(path.join(directory, "coverage.json"), JSON.stringify(result, null, 2) + "\n");
    await writeFile(path.join(directory, "index.html"), page("BEAM line coverage",
      `<p>${summary.covered}/${summary.total} executable lines covered (${percentage(summary)}); ${runs.length} native run(s).</p><table><thead><tr><th>Module</th><th>Lines</th><th>Coverage</th></tr></thead><tbody>${rows}</tbody></table>`));
    return result;
  } finally {
    await rm(temporary, {recursive: true, force: true});
  }
}
