#!/usr/bin/env node
import {readFile, mkdir, readdir, rm, stat, writeFile} from 'node:fs/promises';
import {createHash} from 'node:crypto';
import path from 'node:path';
import {collectNativeSources, settleAdvice} from '../authoring.mjs';
import {createCompiler} from '../api.mjs';
import {
  readManifest,
  writeManifest,
  findManifest,
  dependencyRanges,
  resolveComponent,
} from '../component.mjs';
import {resolveDependencies, packComponent} from '../component-packages.mjs';
import {
  targets,
  artifactTargets,
  templates,
  commands,
  setup,
  prepareCommands,
} from '../templates.mjs';
import {generateExamples} from '../examples-command.mjs';
import {proveWithZ3} from '../proof.mjs';
import {serveLanguage} from '../lsp.mjs';
import {showScalar} from '../scalars.mjs';
import {mutateProject} from '../mutate.mjs';
import {doctor} from '../doctor.mjs';
import {
  buildLength,
  cacheLocation,
  cacheWarning,
  probeCache,
} from '../compiler-cache.mjs';
import {applyRequirements, gradleFor, prepareProject} from '../prepare.mjs';
import {
  recordNativeAttempts,
  nativeSeed,
  attestedKeys,
  readNativeObservations,
  attachNativeEvidence,
  nativeEvidenceText,
} from '../native-evidence.mjs';
import {
  beamCoverageRequirement,
  collectBeamCoverage,
} from '../beam-coverage.mjs';
import {collectScalaCoverage} from '../scala-coverage.mjs';
import {
  captureScalaBuildFailure,
  isScalaCompilationFailure,
} from '../scala-build-state.mjs';
import {failureDatabase, projectKey} from '../failure-database.mjs';
import {spawn, spawnSync} from 'node:child_process';
import {
  benchmarkInvocations,
  presentationInvocations,
  presentationDigest,
  configurationInvocations,
  preparationInvocations,
  environmentDigest,
  executedTests,
  invocations,
  lawKeys,
  previousResult,
  projectDigest,
  recordedDigest,
  selectByTags,
  mergeJunit,
  harnessStatistics,
  coverageTools,
  junitFromTests,
  testsToRun,
} from '../test-command.mjs';
import {
  readOptional,
  planWrites,
  applyWrites,
  atomicWrite,
  safePath,
  collectSources,
} from '../files.mjs';
const VERSION = /*@ version @*/;
const args = process.argv.slice(2);
const verb = args.shift();
const options = {};
const positional = [];
for (let i = 0; i < args.length; i++)
{
  const arg = args[i];
  if (
    [
      '--mutation-timeout',
      '--mutated-generated',
      '--port',
      '--languages',
      '--target',
      '--project',
      '--config',
      '--output',
      '--machine-bits',
      '--example',
      '--seed',
      '--report',
      '--attestation',
      '--view',
      '--solver',
      '--proof-timeout',
      '--proof-memory',
      '--proof-rlimit',
      '--proof-seed',
    ].includes(arg)
  )
  {
    if (!args[i + 1] || args[i + 1].startsWith('--'))
      throw new Error(`Missing value for ${arg}`);
    options[arg.slice(2)] = args[++i];
  }
  else if (['--tag', '--exclude-tag'].includes(arg))
  {
    // Repeatable, and each may list several: --tag a,b --tag c.
    if (!args[i + 1] || args[i + 1].startsWith('--'))
      throw new Error(`Missing value for ${arg}`);
    options[arg.slice(2)] = [
      ...(options[arg.slice(2)] ?? []),
      ...args[++i].split(',').filter(Boolean),
    ];
  }
  else if (
    [
      '--dry-run',
      '--check',
      '--json',
      '--minify',
      '--no-cache',
      '--timings',
      '--no-install',
      '--fresh',
      '--coverage',
      '--update-recorded',
      '--benchmarks',
      '--stdio',
      '--warn-matches',
      '--no-advice',
      '--strict',
      '--compile',
      '--locked',
      '--offline',
    ].includes(arg)
  )
    options[arg.slice(2)] = true;
  else if (arg.startsWith('--')) throw new Error(`Unknown option: ${arg}`);
  else positional.push(arg);
}
let configFile = path.resolve(options.config || 'lawspec.edn');
let configRoot = path.dirname(configFile);
const output = value =>
  console.log(
    typeof value === 'string' ? value : JSON.stringify(value, null, 2),
  );
const shellQuote = value => "'" + String(value).replaceAll("'", "'\\''") + "'";
function testCommand(target, root)
{
  if (artifactTargets.includes(target.language)) return null;
  const testDir = target.testDir || 'test';
  let command = commands[target.language];
  if (target.language === 'python')
    command = `${shellQuote(target.python || 'python3')} -m pytest`;
  if (target.language === 'prolog')
    command = `${shellQuote(target.python || 'python3')} lawspec_test.py`;
  if (target.language === 'java')
    command = `${shellQuote(target.maven || 'mvn')} test`;
  if (target.language === 'kotlin')
    command = `${shellQuote(target.gradle || 'gradle')} test`;
  if (target.language === 'scala')
    command = `${shellQuote(target.scala || 'scala')} test .`;
  if (target.language === 'javascript')
    command = `node --test ${shellQuote(testDir)}/*.test.mjs`;
  if (target.language === 'typescript')
    command = `npm exec -- tsc -p tsconfig.json && node --test ${shellQuote('dist/' + testDir)}/*.test.js`;
  return `(cd ${shellQuote(root)} && ${command})`;
}
// A refuted law fails the command, but evidence still lists it: the
// diagnostics then only say which laws are refuted.
function refutedOnly(result)
{
  return result.diagnostics?.length &&
    result.diagnostics.every(d => d.code === 'refuted') &&
    result.evidence
    ? {...result, refuted: result.diagnostics, diagnostics: []}
    : result;
}

const emittedWarnings = new Set();
function diagnostics(result)
{
  if (!options.json)
  {
    for (const warning of result.warnings ?? [])
    {
      const message = `${warning.at ? `${warning.at.file}:${warning.at.line}:${warning.at.column}: ` : ''}warning ${warning.code}: ${warning.message}`;
      if (!emittedWarnings.has(message))
      {
        console.error(message);
        emittedWarnings.add(message);
      }
    }
  }
  if (result.diagnostics?.length)
    throw Object.assign(
      new Error(
        result.diagnostics
          .map(
            d =>
              `${d.at ? `${d.at.file}:${d.at.line}:${d.at.column}: ` : ''}${d.code}: ${d.message}`,
          )
          .join('\n'),
      ),
      {diagnostics: result.diagnostics},
    );
  return result;
}
async function sources(config)
{
  return lawspecFiles(configRoot, config.sources);
}
async function lawspecFiles(root, entries)
{
  return collectSources(root, entries, configRoot);
}
async function packageInput(owner, root, optional = false)
{
  try
  {
    const resolved = await resolveDependencies(
      path.join(root, 'lawspec.edn'),
      owner,
      {
        locked: !!options.locked,
        readOnly: ['inspect', 'advise'].includes(verb),
        writeLock: !['inspect', 'advise'].includes(verb),
        offline:
          optional || ['inspect', 'advise'].includes(verb) || !!options.offline,
      },
    );
    return {
      packages: resolved.packages,
      dependencies: dependencyRanges(owner),
      ...(owner.package ? {package: owner.package} : {}),
    };
  }
  catch (error)
  {
    if (optional && (error.code === 'ENOENT' || /Offline:/.test(error.message)))
      return {};
    throw error;
  }
}
async function formatCommand()
{
  const config = positional.length ? null : await readManifest(configFile);
  const root = positional.length ? process.cwd() : configRoot;
  const files = await collectSources(
    root,
    positional.length ? positional : config.sources,
  );
  const compiler = await createCompiler();
  const result = diagnostics(
    await compiler.format({
      sources: files,
      compile: !!options.compile,
      machineBits: options.machineBits ?? 64,
      ...(config
        ? await packageInput(config, configRoot, !options.compile)
        : {}),
      languageProfile: '1.0-rc.2',
      verification: {layers: []},
    }),
  );
  const changed = result.formattedSources.filter(
    (file, index) => file.content !== files[index].content,
  );
  if (!options.check)
    for (const file of changed)
      await atomicWrite(path.resolve(root, file.path), file.content);
  output(
    options.json
      ? {changed: changed.map(file => file.path), check: !!options.check}
      : changed.length
        ? `${changed.length} source file(s) ${options.check ? 'need formatting' : 'formatted'}.`
        : 'All sources are formatted.',
  );
  if (options.check && changed.length) process.exitCode = 1;
}

async function packageCommand()
{
  const file = options.config
    ? configFile
    : path.resolve(options.project || '.', 'lawspec.edn');
  const directory = path.dirname(file);
  const manifest = await readManifest(file);
  if (!manifest.package)
    throw new Error(`${file}: expected a package identity`);
  const own = {
    ...manifest.package,
    dependencies: dependencyRanges(manifest),
    sources: await lawspecFiles(directory, manifest.sources),
  };
  const compiler = await createCompiler();
  const result = diagnostics(
    await compiler.check({
      languageProfile: '1.0-rc.2',
      verification: {layers: []},
      sources: own.sources,
      package: {name: own.name, version: own.version},
      ...(await packageInput(manifest, directory)),
      machineBits: options.machineBits ?? 64,
    }),
  );
  // A package owns the units in its namespace; its dependencies' units are not its own.
  const units = result.units
    .map(u => u.id)
    .filter(u => u === own.name || u.startsWith(own.name + '.'));
  const laws = result.laws.filter(l => units.includes(l.owner));
  const summary = {
    name: own.name,
    version: own.version,
    dependencies: own.dependencies,
    units,
    laws: laws.map(l => `${l.owner}::${l.name}`),
    dataTypes: result.dataTypes
      .filter(d => units.some(u => d.id.startsWith(u + '::')))
      .map(d => d.id),
  };
  if (options.output)
    summary.archive = await packComponent(file, options.output);
  output(
    options.json
      ? summary
      : `${summary.name} ${summary.version}: ${units.length} unit(s), ${summary.laws.length} law(s), ${summary.dataTypes.length} data type(s).
` +
          `Units: ${units.join(', ')}
` +
          `Dependencies: ${
            Object.entries(summary.dependencies)
              .map(([n, r]) => `${n} ${r}`)
              .join(', ') || 'none'
          }`,
  );
}
async function init()
{
  const language = options.target;
  if (!targets.includes(language))
    throw new Error(`Choose --target ${targets.join('|')}`);
  if (path.extname(configFile) !== '.edn')
    throw new Error(
      'Use lawspec.edn; JSON configuration is no longer supported',
    );
  for (const old of ['lawspec.json', 'lawspec-package.json'])
  {
    if ((await readOptional(path.join(configRoot, old))) !== null)
      throw new Error(`${old} is no longer supported; use lawspec.edn`);
  }
  const current = await readOptional(configFile);
  const config =
    current === null
      ? {
          manifestVersion: 1,
          component: {name: path.basename(configRoot), version: '0.1.0'},
          languageProfile: '1.0-rc.2',
          verification: {layers: []},
          sources: ['laws'],
          targets: [],
        }
      : await readManifest(configFile);
  const declared = config.targets.filter(
    target => target.language === language,
  );
  if (options.project === undefined && declared.length > 1)
  {
    throw new Error(
      `Several ${language} targets are configured; choose the root with --project`,
    );
  }
  const root = path.resolve(
    configRoot,
    options.project ?? declared[0]?.root ?? '.',
  );
  const configured = config.targets.some(
    t => t.language === language && path.resolve(configRoot, t.root) === root,
  );
  await mkdir(root, {recursive: true});
  const buildFiles = [
    'Cargo.toml',
    'pom.xml',
    'pyproject.toml',
    'package.json',
    'go.mod',
    'stack.yaml',
    'package.yaml',
    'build.gradle',
    'build.gradle.kts',
    'settings.gradle.kts',
    'rebar.config',
    'mix.exs',
    'gleam.toml',
  ];
  const scaffold = templates(language, {minify: options.minify === true});
  // A file init itself would write also marks the project as set up, so that
  // running init again never stops on its own earlier output.
  const scaffolded = (
    await Promise.all(
      Object.keys(scaffold).map(name => readOptional(path.join(root, name))),
    )
  ).some(content => content !== null);
  const hasBuild =
    scaffolded ||
    (await readdir(root)).some(
      f => buildFiles.includes(f) || f.endsWith('.cabal'),
    );
  const additions = hasBuild ? {} : scaffold;
  for (const name of Object.keys(additions))
  {
    const file = await safePath(root, name);
    if ((await readOptional(file)) !== null)
      throw new Error(`Will not overwrite ${file}`);
  }
  const starter = await safePath(configRoot, 'laws/atoi_codec.lawspec');
  await safePath(configRoot, path.basename(configFile));
  if (current === null && (await readOptional(starter)) !== null)
    throw new Error(
      'Starter specification already exists; create lawspec.edn manually to use it',
    );
  if (!hasBuild && language !== 'go')
    await mkdir(path.join(root, 'src'), {recursive: true});
  for (const [name, content] of Object.entries(additions))
    await atomicWrite(path.join(root, name), content, true);
  // A project that already has build files keeps them; only the settings a
  // JSON build file lacks are added. ref:DEC-init-prepares-project
  const adjusted = hasBuild
    ? await applyRequirements(language, root, {minify: options.minify === true})
    : {created: [], updated: []};
  if (current === null)
    await atomicWrite(
      starter,
      artifactTargets.includes(language) && language !== 'make'
        ? 'unit configuration\ntype Settings is a record{port :: UInt16 enabled :: Bool} end type\nfunction settings (unused :: Unit) -> Settings is Settings record{port = 8080, enabled = true} end function\nend unit\n'
        : (
            await readFile(
              new URL('../starter-rc1.lawspec', import.meta.url),
              'utf8',
            )
          ).replace(/^-- Generated[^\r\n]*Do not edit\.\r?\n/, ''),
      true,
    );
  if (options.machineBits !== undefined)
    config.machineBits = options.machineBits;
  if (!configured)
    config.targets.push({
      language,
      root: path.relative(configRoot, root) || '.',
    });
  if (current === null || !configured || options.machineBits !== undefined)
  {
    await atomicWrite(
      configFile,
      writeManifest(config, {compact: options.minify === true}),
      current === null,
    );
  }
  const changes = [
    ...adjusted.created.map(file => `created ${file}`),
    ...adjusted.updated.map(entry => `updated ${entry}`),
  ];
  const summary = `Configured ${language}. ${
    hasBuild
      ? `Existing build files preserved${changes.length ? `; ${changes.join('; ')}` : ''}.`
      : 'Created missing project build files.'
  }`;
  if (options['no-install'])
  {
    output(
      `${summary}\n${setup[language]}\nNext: lawspec doctor, then lawspec generate.`,
    );
    return;
  }
  const target = config.targets.find(
    t => t.language === language && path.resolve(configRoot, t.root) === root,
  );
  let report;
  try
  {
    const prepared = await prepareProject(target, root, {added: !configured});
    if (prepared.python !== undefined)
    {
      target.python = prepared.python;
      await atomicWrite(
        configFile,
        writeManifest(config, {compact: options.minify === true}),
      );
    }
    report = await doctor(target, root);
  }
  catch (error)
  {
    report = {ok: false, message: error.message, instructions: setup[language]};
  }
  if (report.ok)
  {
    output(
      `${summary}\n${
        report.kind === 'artifact'
          ? setup[language]
          : prepareCommands[language].length
            ? 'Dependencies are installed and lawspec doctor passes.'
            : 'lawspec doctor passes.'
      }\nNext: lawspec generate${report.kind === 'artifact' ? '' : ', then lawspec test'}.`,
    );
    return;
  }
  output(
    `${summary}\n${language} is not ready: ${report.message}\n${report.instructions}\nCorrect this and run lawspec init --target ${language} again, or lawspec doctor to check.`,
  );
  process.exitCode = 1;
}
function showAssertion(assertion)
{
  if (assertion.kind === 'equal')
    return `${assertion.left.text} = ${assertion.right.text}`;
  if (assertion.kind === 'implies')
    return `${assertion.guard.text} implies ${showAssertion(assertion.body)}`;
  return assertion.items.map(showAssertion).join(' and ');
}
// An ability key, as the spec names it: example.shop::ability::Store(Int32)
// is Store Int32, lawspec::ability::Fail(example.shop::type::E) is Fail E.
function abilityName(key)
{
  const short = text => text.replace(/[A-Za-z0-9_.]+::(ability|type)::/g, '');
  const match = /^(.*?)(\((.*)\))?$/.exec(short(key));
  return match[3]
    ? `${match[1]} ${match[3].replace(/[()]/g, ' ').replace(/;/g, ' ').trim()}`
    : match[1];
}
// The handlers a law runs under, and the ability row of each function its
// expansion calls.
function explainAbilities(law, expansion, units)
{
  const unit = (units || []).find(u => u.id === law.owner);
  const called = (unit ? unit.declarations : []).filter(
    d => d.uses && new RegExp(`\\b${d.name}\\b`).test(expansion),
  );
  const handlers = (law.handlers || [])
    .map(h => `\n  ${abilityName(h.ability)}: ${h.handler}`)
    .join('');
  const rows = called
    .map(d => `\n  ${d.name} uses ${d.uses.map(abilityName).join(', ')}`)
    .join('');
  return (
    (handlers ? `\nhandlers${handlers}` : '') + (rows ? `\nrows${rows}` : '')
  );
}
function explainExamples(law)
{
  return law.examples
    .map(
      ex =>
        `\nexample ${JSON.stringify(ex.name)}\n` +
        ex.bindings
          .map(b => `  ${b.name} = ${showScalar(b.value)}`)
          .join('\n') +
        '\n' +
        ex.expectations.map(e => `  expect ${showAssertion(e)}`).join('\n'),
    )
    .join('\n');
}
// What lawspec test last recorded for each law, across targets, and the
// environment attestations its runs were given, by run id. A law passed in
// an attested run names that run; across targets, its latest passing run.
async function lastRuns()
{
  const folder = path.join(configRoot, '.lawspec', 'results');
  const runs = new Map();
  const attestations = new Map();
  // The outcome each law last had in each attested run, by run id; across
  // targets a failure outweighs a pass.
  const outcomes = new Map();
  const rank = o =>
    ['passed', 'known-discrepancy', 'skipped', 'incomplete', 'failed'].indexOf(
      o,
    );
  for (const name of (await readOptionalDirectory(folder)) ?? [])
  {
    if (!name.endsWith('.json')) continue;
    const recorded = JSON.parse(
      (await readOptional(path.join(folder, name))) ?? '{}',
    );
    for (const [id, attestation] of Object.entries(recorded.attestations ?? {}))
      attestations.set(id, attestation);
    const outcome = (id, law, value) =>
    {
      const known = outcomes.get(id) ?? {};
      if (known[law] === undefined || rank(value) > rank(known[law]))
        known[law] = value;
      outcomes.set(id, known);
    };
    for (const [law, attempt] of Object.entries(recorded.attempts ?? {}))
      if (attempt.environment)
        outcome(attempt.environment, law, attempt.outcome);
    for (const [law, run] of Object.entries(recorded.laws ?? {}))
      if (
        run.environment &&
        recorded.attempts?.[law]?.environment !== run.environment
      )
        outcome(run.environment, law, 'passed');
    for (const [law, run] of Object.entries(recorded.laws ?? {}))
    {
      const known = runs.get(law) ?? {};
      const latest = (known.passed ?? '') > (run.passed ?? '') ? known : run;
      runs.set(law, {
        flaky: known.flaky || run.flaky,
        adequacy: run.adequacy ?? known.adequacy,
        passed: latest.passed,
        seed: latest.seed,
        environment: latest.environment,
      });
    }
  }
  return {runs, attestations, outcomes};
}
// An environment attestation: a versioned JSON document any tool may write,
// recording for one run where each dependency was wired and whether it was
// the real dependency or a stand-in. --attestation names one, or lawspec.edn
// does; the compiler checks it. It is reporting only and changes no evidence.
async function readAttestation(config)
{
  const file =
    options.attestation !== undefined
      ? path.resolve(options.attestation)
      : config.attestation !== undefined
        ? path.resolve(configRoot, config.attestation)
        : null;
  if (file === null) return null;
  const text = await readOptional(file);
  if (text === null) throw new Error(`No environment attestation at ${file}`);
  try
  {
    return JSON.parse(text);
  }
  catch (error)
  {
    throw new Error(
      `${file}: the environment attestation is not JSON: ${error.message}`,
    );
  }
}
// One attested dependency, as lawspec evidence shows it.
function dependencyText(d)
{
  const level = c =>
    /^[0-9]+$/.test(c) ? `conformance level ${c}` : `conformance ${c}`;
  const ran = d.ranAgainst ?? {};
  const history = ran.historyDigest ?? d.standIn?.historyDigest;
  return (
    `${d.dependency}: ` +
    (d.standIn
      ? `stand-in ${d.standIn.identity} ${d.standIn.version} (${level(d.standIn.conformance)}` +
        (history
          ? `, history ${history}${ran.historyFrom === 'completed' ? ' when completed' : ''}`
          : '') +
        ')'
      : 'real') +
    ` at ${d.endpoint}` +
    (d.reached ? '' : ' (not reached when recorded)') +
    (d.implementation
      ? `; ${d.implementation.kind} ${d.implementation.product} ${d.implementation.version}`
      : '') +
    (d.contract
      ? `; contract ${d.contract.package} ${d.contract.version}`
      : '') +
    (d.node ? `; node ${d.node}` + (d.edge ? ` via ${d.edge}` : '') : '') +
    (d.completed && !d.completed.reached ? ' (not reached when completed)' : '')
  );
}
// What an attested run's document records, as lawspec evidence shows it.
function executionText(run)
{
  const e = run?.execution;
  if (!e) return '';
  return e.status === 'completed'
    ? `, completed with exit code ${e.exitCode}`
    : e.status === 'running'
      ? ', in progress'
      : ', wiring only';
}
// Why a law relying on an attested dependency has no completed run linked.
function unlinkedText(run)
{
  const status = run?.execution?.status;
  return status === 'wired'
    ? 'wiring only; nothing ran'
    : status === 'running'
      ? 'run in progress; no completed run linked'
      : 'no completed run linked';
}
// One law's harness, as lawspec evidence shows it.
function harnessText(item)
{
  const h = item.harness ?? {};
  const parts = [];
  if (h.unit) parts.push(`harness ${h.unit}`);
  if (h.tags?.length) parts.push(`tags ${h.tags.join(', ')}`);
  if (h.strategies?.length)
    parts.push(
      h.strategies.map(s => `${s.input} drawn by ${s.strategy}`).join(', '),
    );
  for (const c of h.cover ?? [])
    parts.push(`cover ${c.percent}% "${c.label}" when ${c.when.text}`);
  for (const c of h.classify ?? [])
    parts.push(`classify ${c.when.text} as "${c.label}"`);
  for (const l of h.labels ?? []) parts.push(`label ${l.text}`);
  if (h.target) parts.push(`target maximize ${h.target.text}`);
  if (h.timeoutMilliseconds) parts.push(`timeout ${h.timeoutMilliseconds} ms`);
  if (h.repeat > 1) parts.push(`repeat ${h.repeat}`);
  if (h.retries) parts.push(`retry flaky ${h.retries}`);
  if (h.skip) parts.push(`skip "${h.skip}"`);
  if (h.knownDiscrepancy)
    parts.push(`known discrepancy "${h.knownDiscrepancy}"`);
  if (h.orderRandom) parts.push('order random');
  if (h.parallel) parts.push('parallel');
  const lines = [
    `  ${item.declaration.replace('::law::', '::')}: ${parts.join('; ') || 'no harness settings'}`,
  ];
  for (const run of item.adequacy ?? [])
  {
    lines.push(
      `    last run: ${run.cases} generated case(s)` +
        (run.cover ?? [])
          .map(
            c =>
              `; cover "${c.label}" ${c.observed}% (needs ${c.required}%)${c.met ? '' : ' NOT MET'}`,
          )
          .join(''),
    );
    const counts = {
      ...(run.classes ?? {}),
      ...Object.fromEntries(
        Object.entries(run.labels ?? {}).map(([k, v]) => [`label ${k}`, v]),
      ),
    };
    if (Object.keys(counts).length)
      lines.push(
        `    ${Object.entries(counts)
          .map(
            ([k, v]) =>
              `${k}: ${run.cases ? ((100 * v) / run.cases).toFixed(1) : 0}%`,
          )
          .join(', ')}`,
      );
  }
  return lines.join('\n');
}
// The compiler keeps work between runs in a cache directory, in one folder
// per compiler build, so a different build never reads another's entries.
// By default that is .lawspec/cache, which LawSpec owns: it removes other
// builds' folders there, and a command that fails removes the .lawspec
// folder if it created it, leaving the project as it was. A directory named
// by LAWSPEC_COMPILER_CACHE or :cache-directory may be shared by projects
// and compiler versions, so nothing is removed from it.
let createdState = null;
async function cacheDirectory(config)
{
  const location = cacheLocation({options, config, configRoot});
  if (location === undefined) return undefined;
  if (!location.owned)
  {
    await mkdir(location.directory, {recursive: true}).catch(() =>
    {});
    return location.directory;
  }
  const folder = location.directory;
  const build = (await buildDigest()).slice(0, buildLength);
  const state = path.join(configRoot, '.lawspec');
  if ((await readOptionalDirectory(state)) === null) createdState = state;
  await mkdir(folder, {recursive: true});
  await writeFile(path.join(folder, '.gitignore'), '*\n');
  // lawspec prove keeps solver receipts beside the build's folder. They name
  // the build they belong to, and go when another build's folder goes.
  const receipts = 'solver-goals-v1';
  const stale = (await readdir(folder)).filter(
    entry => ![build, '.gitignore', receipts].includes(entry),
  );
  for (const entry of stale.length ? [...stale, receipts] : [])
    await rm(path.join(folder, entry), {recursive: true, force: true});
  return folder;
}
// An entry the compiler could not store changes no result, so it is reported
// once, on standard error, and never in a command's own output.
let cacheWarned = false;
function reportingCache(compiler)
{
  return Object.fromEntries(
    Object.entries(compiler).map(([name, method]) => [
      name,
      async input =>
      {
        const result = await method(input);
        if (result?.cacheFailure)
        {
          if (!cacheWarned) console.error(cacheWarning(result.cacheFailure));
          cacheWarned = true;
          delete result.cacheFailure;
        }
        return result;
      },
    ]),
  );
}
// The compiler build, by the digest of its WebAssembly module.
let buildDigestValue = null;
async function buildDigest()
{
  buildDigestValue ??= createHash('sha256')
    .update(await readFile(new URL('../core.wasm', import.meta.url)))
    .digest('hex');
  return buildDigestValue;
}
// lawspec test: run the tests of the laws whose results may have changed,
// and record each passing law's key and seed (see test-command.mjs). The
// harness plane chooses which: --tag and --exclude-tag select laws by their
// harness tags, and a skipped law runs nothing. A law whose last run failed
// runs first, and its failing inputs are replayed first (.lawspec/failures).
// `lawspec mutate` names the generated files its mutant edited, relative to
// the working directory. A test run leaves exactly those files as edited.
function mutatedGenerated(file)
{
  const named = (options['mutated-generated'] ?? '')
    .split(',')
    .filter(Boolean)
    .map(name => path.resolve(name));
  return named.includes(path.resolve(file));
}

async function runTests(compiler, input, selected, roots, config)
{
  // Recorded values live beside lawspec.edn, under recorded/<unit>/<name>.
  const recordedFolder = path.join(configRoot, 'recorded');
  const seed =
    options.seed ?? String(1 + Math.floor(Math.random() * 2147483646));
  const offline = process.env.LAWSPEC_OFFLINE === '1';
  const build = await buildDigest();
  const summaries = [];
  const junit = [];
  const report =
    options.report === undefined ? null : parseReport(options.report);
  const attestation = await readAttestation(config);
  for (const [i, target] of selected.entries())
  {
    const root = roots[i];
    const planned = diagnostics(
      await compiler.planGeneration({
        ...input,
        target: target.language,
        sourceDir: target.sourceDir,
        testDir: target.testDir,
        nativeBindings: target.nativeBindings,
        actors: target.actors,
        minify: options.minify === true,
        ...(attestation ? {attestation} : {}),
      }),
    );
    // The laws the attestation touches, each with how its dependencies
    // were wired (the run's id and times aside).
    const attested = attestedKeys(planned);
    if (!planned.tests.length && !options.benchmarks)
    {
      summaries.push({
        target: target.language,
        root: target.root,
        seed: nativeSeed(seed),
        ran: [],
        unchanged: 0,
        ok: true,
        testsExecuted: 0,
        selection: 'no-selected-native-checks',
      });
      continue;
    }
    const pending = await planWrites(root, planned.files, {
      edited: mutatedGenerated,
    });
    if (pending.changes.length)
      throw new Error(
        `${target.language}: generated files are out of date; run lawspec generate${options.minify ? ' --minify' : ''}`,
      );
    for (const preparation of configurationInvocations(target))
    {
      const result = await spawned(
        preparation.command,
        preparation.args,
        root,
        process.env,
      );
      if (!result.ok)
        throw new Error(
          `${target.language}: native build metadata preparation failed`,
        );
    }
    const report_ = await doctor(target, root, planned.files);
    if (!report_.ok)
      throw new Error(
        `${target.language}: ${report_.message}\n${report_.instructions}`,
      );
    const generated = new Set(
      planned.files.filter(f => f.ownership === 'generated').map(f => f.path),
    );
    const keys = lawKeys({
      build,
      target,
      machineBits: input.machineBits,
      minify: options.minify === true,
      tests: planned.tests,
      // Recorded values are spec data: a changed recording runs its laws again.
      environment: await environmentDigest(root, report_, target.language),
      recorded: await recordedDigest(recordedFolder),
      project: await projectDigest(root, generated, target.language, {
        inputRoot: configRoot,
        inputs: config.inputs ?? [],
      }),
      attested,
    });
    const identity = projectKey(root);
    const resultsFile = path.join(
      configRoot,
      '.lawspec',
      'results',
      `${target.language}-${identity}.json`,
    );
    const previous = JSON.parse(
      (await readOptional(resultsFile)) ?? '{"version":1,"laws":{}}',
    );
    const presentation = presentationDigest(
      planned.files,
      await environmentDigest(root, report_, target.language),
    );
    if (previous.presentation !== presentation)
    {
      const checks = presentationInvocations(target, planned.files, {offline});
      if (!checks.length)
        throw new Error(
          `${target.language}: no native source validator is available`,
        );
      for (const check of checks)
      {
        const result = await spawned(check.command, check.args, root, {
          ...process.env,
          ...check.environment,
        });
        if (!result.ok)
          throw new Error(
            target.language === 'go' &&
              /New\w+Bound/.test(result.output) &&
              result.output.includes('redeclared in this block')
              ? 'Go handler bridge conflicts with an existing New<Ability>Bound workaround. Remove or rename that manual wrapper; user-owned adapters have been preserved.'
              : `${target.language}: current generated source failed native validation`,
          );
      }
    }
    const attempts = {...(previous.attempts ?? {})};
    const {
      directory: failures,
      file: databaseFile,
      database,
    } = await failureDatabase(configRoot, target.language, root);
    // Recording again runs every law, so each records what it sees now.
    const chosen = selectByTags(
      planned.tests,
      options.tag ?? [],
      options['exclude-tag'] ?? [],
    );
    const stale = testsToRun(chosen, keys, previous.laws, database, {
      fresh: options.fresh,
      coverage: options.coverage,
      updateRecorded: options['update-recorded'],
    });
    // The failure database: each law whose last run failed, with the seed
    // that exposed it. Those laws run first, with that seed, so the failing
    // inputs are generated again; the runtimes keep their own counterexample
    // databases beside it (Hypothesis, proptest).
    const replayed =
      options.seed === undefined
        ? stale.filter(entry => database[entry.law])
        : [];
    const batches = [
      ...[
        ...new Set(replayed.map(entry => nativeSeed(database[entry.law].seed))),
      ].map(s => ({
        seed: String(s),
        entries: replayed.filter(
          entry => nativeSeed(database[entry.law].seed) === s,
        ),
      })),
      {seed, entries: stale.filter(entry => !replayed.includes(entry))},
    ].filter(batch => batch.entries.length);
    const profile = {
      target: target.language,
      root,
      machineBits: input.machineBits,
      minify: options.minify === true,
      build,
    };
    // Persist pending attempts before starting a native process. Interrupted or
    // failed setup cannot leave an older passing cache entry looking completed.
    for (const entry of stale)
    {
      Object.assign(
        attempts,
        recordNativeAttempts({laws: [entry], command: null}, [], {
          keys,
          seed,
          ok: false,
          profile,
          allEntries: planned.tests,
        }),
      );
    }
    const pendingLaws = Object.fromEntries(
      Object.entries(previous.laws ?? {}).filter(
        ([id]) => !stale.some(entry => entry.law === id),
      ),
    );
    await mkdir(path.dirname(resultsFile), {recursive: true});
    await writeFile(path.join(path.dirname(resultsFile), '.gitignore'), '*\n');
    await atomicWrite(
      resultsFile,
      JSON.stringify(
        {...previous, version: 1, laws: pendingLaws, attempts},
        null,
        2,
      ) + '\n',
    );
    const passed = [];
    const unrun = [];
    let failed = false;
    const scratch = path.join(
      configRoot,
      '.lawspec',
      'reports',
      target.language,
      identity,
    );
    const stats = path.join(scratch, 'statistics');
    const beam = ['erlang', 'elixir', 'gleam'].includes(target.language);
    const coverage = options.coverage
      ? path.join(configRoot, '.lawspec', 'coverage', target.language, identity)
      : null;
    const coverageRuns = [];
    let coverageWritten = false,
      coverageError;
    await rm(scratch, {recursive: true, force: true});
    await mkdir(stats, {recursive: true});
    await mkdir(failures, {recursive: true});
    await writeFile(
      path.join(configRoot, '.lawspec', 'reports', '.gitignore'),
      '*\n',
    );
    const missingCoverage = coverage
      ? await coverageMissing(target, root, report_)
      : null;
    const useCoverage = coverage && !missingCoverage;
    if (missingCoverage)
      console.error(
        `${target.language}: --coverage needs ${missingCoverage.tool}, which is not available; ${missingCoverage.install}. Running without coverage.`,
      );
    if (useCoverage)
    {
      if (beam || target.language === 'scala')
        await rm(coverage, {recursive: true, force: true});
      await mkdir(beam ? path.join(coverage, 'runs') : coverage, {
        recursive: true,
      });
    }
    // Python may use xdist processes; the host harness otherwise supplies
    // its existing thread scheduler, which Prolog also uses through Janus.
    let xdist = false;
    if (target.language === 'python' && stale.some(entry => entry.parallel))
    {
      xdist =
        spawnSync(target.python || 'python3', ['-c', 'import xdist'], {
          cwd: root,
          stdio: 'ignore',
        }).status === 0;
    }
    // A skipped law runs nothing. BEAM known-discrepancy checks finish as native
    // passing tests, so their completion must appear in the native report.
    const expected = entry =>
      !entry.skip &&
      (!entry.knownDiscrepancy ||
        ['erlang', 'elixir', 'gleam'].includes(target.language));
    const benchmarking = options.benchmarks ? (planned.benchmarks ?? []) : [];
    if (batches.length || benchmarking.length)
    {
      for (const preparation of preparationInvocations(target, planned.files))
      {
        const {ok} = await spawned(
          preparation.command,
          preparation.args,
          root,
          process.env,
        );
        if (!ok)
          throw new Error(`${target.language}: native test preparation failed`);
      }
    }
    const seedOf = new Map();
    batches: for (const batch of batches)
    {
      for (const run of invocations(target, batch.entries, {
        offline,
        scratch,
        coverage: useCoverage ? coverage : null,
        xdist,
        root,
        coverageConfig: report_.coverage,
      }))
      {
        const since = Date.now();
        const {ok, output} = await spawned(
          run.command,
          run.args,
          root,
          {
            ...process.env,
            ...run.env,
            LAWSPEC_SEED: batch.seed,
            HSPEC_SEED: batch.seed,
            LAWSPEC_STATS: stats,
            LAWSPEC_FAILURES: failures,
            LAWSPEC_RECORDED: recordedFolder,
            ...(options['update-recorded']
              ? {LAWSPEC_UPDATE_RECORDED: '1'}
              : {}),
          },
          run.report?.kind === 'go-json',
        );
        if (
          !ok &&
          target.language === 'scala' &&
          isScalaCompilationFailure(output)
        )
        {
          const directory = await captureScalaBuildFailure({
            root,
            command: run.command,
            args: run.args,
            output,
          });
          if (directory) console.error(`Scala compiler state: ${directory}`);
        }
        if (run.coverage) coverageRuns.push(run.coverage);
        const executed = await executedTests(run.report, output, root, since);
        const observed = recordNativeAttempts(run, executed, {
          keys,
          seed: batch.seed,
          ok,
          profile,
          output,
          allEntries: planned.tests,
        });
        if (!ok && !run.laws.length)
          Object.assign(
            attempts,
            recordNativeAttempts(
              {laws: batch.entries, command: run.command},
              [],
              {
                keys,
                seed: batch.seed,
                ok: false,
                profile,
                output,
                allEntries: planned.tests,
              },
            ),
          );
        Object.assign(attempts, observed);
        for (const law of run.laws) seedOf.set(law.law, batch.seed);
        // A completed combined model method remains scoped to its own checks,
        // even if another selected method in this invocation failed.
        passed.push(
          ...run.laws.filter(
            entry =>
              ['passed', 'known-discrepancy'].includes(
                observed[entry.law]?.outcome,
              ) || !expected(entry),
          ),
        );
        if (report)
          junit.push({
            target: `${target.language} (${target.root})`,
            xml: await junitOf(run, executed, root, since),
          });
        if (!ok || executed.some(test => test.status === 'failed'))
        {
          failed = true;
          break batches;
        }
        // A runner whose filter matched nothing reports success, so a law
        // counts as passed only if the runner's report shows its tests ran.
        unrun.push(
          ...run.laws.filter(
            entry => !passed.includes(entry) && expected(entry),
          ),
        );
      }
    }
    if (unrun.length) failed = true;
    if (useCoverage && target.language === 'scala' && !failed)
    {
      try
      {
        coverageWritten = await collectScalaCoverage({
          root,
          directory: coverage,
          command: target.scala || 'scala',
          offline,
        });
      }
      catch (error)
      {
        failed = true;
        coverageError = error.message;
      }
    }
    if (useCoverage && beam)
    {
      try
      {
        coverageWritten = !!(await collectBeamCoverage({
          root,
          directory: coverage,
          runs: coverageRuns,
        }));
      }
      catch (error)
      {
        failed = true;
        coverageError = error.message;
      }
    }
    // --benchmarks: the harness's benchmarks run after the laws, every time;
    // they are measured, never asserted, and never cached.
    if (!failed)
      for (const run of benchmarkInvocations(target, benchmarking, {offline}))
      {
        const {ok} = await spawned(
          run.command,
          run.args,
          root,
          {
            ...process.env,
            ...run.env,
            LAWSPEC_SEED: seed,
            HSPEC_SEED: seed,
            LAWSPEC_STATS: stats,
            LAWSPEC_RECORDED: recordedFolder,
          },
          false,
        );
        if (!ok)
        {
          failed = true;
          break;
        }
      }
    const statistics = await harnessStatistics(stats);
    // A renamed law keeps its result: it is found by its key.
    const kept = entry =>
      previous.laws[entry.law] ??
      previousResult(previous.laws, entry.law, keys.get(entry.law));
    const laws = Object.fromEntries(
      planned.tests.filter(kept).map(entry => [entry.law, kept(entry)]),
    );
    for (const entry of passed)
    {
      const label = entry.label;
      const observed = statistics.filter(s => s.law === label);
      laws[entry.law] = {
        key: keys.get(entry.law),
        seed: nativeSeed(seedOf.get(entry.law) ?? seed),
        passed: new Date().toISOString(),
        // A law the attestation touches names the run it passed in.
        ...(attestation && attested.has(entry.law)
          ? {environment: attestation.run.id}
          : {}),
        ...(observed.some(s => s.outcome === 'flaky') ? {flaky: true} : {}),
        ...(observed.some(s => s.cover || s.labels || s.classes)
          ? {
              adequacy: observed
                .filter(s => s.cover || s.labels || s.classes)
                .map(({test, cases, cover, classes, labels}) => ({
                  test,
                  cases,
                  cover,
                  classes,
                  labels,
                })),
            }
          : {}),
      };
    }
    // A law that failed is recorded with its seed; one that passed leaves.
    for (const entry of stale)
    {
      if (passed.includes(entry)) delete database[entry.law];
      else
      {
        delete laws[entry.law];
        if (!seedOf.has(entry.law)) continue;
        database[entry.law] = {
          seed: nativeSeed(seedOf.get(entry.law)),
          failed: new Date().toISOString(),
        };
      }
    }
    await writeFile(
      path.join(configRoot, '.lawspec', 'failures', '.gitignore'),
      '*\n',
    );
    await writeFile(databaseFile, JSON.stringify(database, null, 2) + '\n');
    await mkdir(path.dirname(resultsFile), {recursive: true});
    await writeFile(path.join(path.dirname(resultsFile), '.gitignore'), '*\n');
    // Each attempt at a law the attestation touches names the run it was
    // made in, whatever its outcome.
    if (attestation)
      for (const entry of stale)
      {
        if (!seedOf.has(entry.law) || !attempts[entry.law]) continue;
        attempts[entry.law] = {
          ...attempts[entry.law],
          executionRun: attestation.run.id,
          ...(attested.has(entry.law) ? {environment: attestation.run.id} : {}),
        };
      }
    // Each attestation a recorded law ran under is kept with the results.
    const attestations = Object.fromEntries(
      Object.entries({
        ...(previous.attestations ?? {}),
        ...(attestation ? {[attestation.run.id]: attestation} : {}),
      }).filter(([id]) =>
        [...Object.values(laws), ...Object.values(attempts)].some(
          run => run.environment === id || run.executionRun === id,
        ),
      ),
    );
    await atomicWrite(
      resultsFile,
      JSON.stringify(
        {
          version: 1,
          laws,
          attempts,
          presentation,
          ...(Object.keys(attestations).length ? {attestations} : {}),
        },
        null,
        2,
      ) + '\n',
    );
    const flaky = statistics.filter(s => s.outcome === 'flaky').map(s => s.law);
    const unmet = statistics.flatMap(s =>
      (s.cover ?? [])
        .filter(c => !c.met)
        .map(
          c => `${s.law}: cover ${c.required}% "${c.label}" (${c.observed}%)`,
        ),
    );
    const benchmarks = statistics.filter(s => s.benchmark);
    // How each parallel unit's tests actually ran at the same time.
    const parallelism = statistics
      .filter(s => s.parallel)
      .map(({parallel, mode, workers}) => ({unit: parallel, mode, workers}));
    summaries.push({
      target: target.language,
      root: target.root,
      seed: nativeSeed(seed),
      ran: stale.map(e => e.law),
      ...(attestation ? {environment: attestation.environment} : {}),
      unchanged: chosen.length - stale.length,
      ok: !failed,
      failedLaws: stale
        .filter(
          entry =>
            attempts[entry.law]?.outcome === 'failed' &&
            (attempts[entry.law]?.check?.nativeGroup?.length ?? 1) === 1 &&
            attempts[entry.law]?.tests?.some(test => test.status === 'failed'),
        )
        .map(entry => entry.law),
      ...(chosen.length !== planned.tests.length
        ? {deselected: planned.tests.length - chosen.length}
        : {}),
      ...(unrun.length ? {unrun: unrun.map(e => e.law)} : {}),
      ...(flaky.length ? {flaky: [...new Set(flaky)]} : {}),
      ...(unmet.length ? {unmetCover: unmet} : {}),
      ...(benchmarks.length ? {benchmarks} : {}),
      ...(parallelism.length ? {parallelism} : {}),
      ...(coverageError ? {coverageError} : {}),
      ...(useCoverage &&
      ((!beam && target.language !== 'scala') || coverageWritten)
        ? {coverage: path.relative(process.cwd(), coverage) || '.'}
        : {}),
    });
  }
  if (report)
  {
    await mkdir(path.dirname(path.resolve(report.path)), {recursive: true});
    await writeFile(path.resolve(report.path), mergeJunit(junit));
  }
  output(
    options.json
      ? summaries
      : summaries
          .map(
            s =>
              `${s.target}${summaries.filter(other => other.target === s.target).length > 1 ? ` (${s.root})` : ''}: ${s.ran.length ? `ran ${s.ran.length} law(s) with seed ${s.seed}${s.environment ? ` in environment ${s.environment}` : ''}` : 'nothing to run'}` +
              (s.selection === 'no-selected-native-checks'
                ? '; no native checks selected; intrinsic definition checks passed.'
                : `, ${s.unchanged} unchanged since their last passing run.${s.ok ? '' : ' FAILED'}`) +
              (s.deselected
                ? `\n${s.deselected} law(s) not selected by --tag or --exclude-tag.`
                : '') +
              (s.unrun
                ? `\nNo tests ran for ${s.unrun.join(', ')}; the runner matched none of their tests.`
                : '') +
              (s.flaky
                ? `\nFlaky (failed, then passed on a retry): ${s.flaky.join(', ')}`
                : '') +
              (s.unmetCover
                ? `\nCover not met: ${s.unmetCover.join('; ')}`
                : '') +
              (s.parallelism
                ? '\n' +
                  s.parallelism
                    .map(
                      p =>
                        `parallel ${p.unit}: ${p.mode}, ${p.workers} worker(s)`,
                    )
                    .join('\n')
                : '') +
              (s.benchmarks
                ? '\n' +
                  s.benchmarks
                    .map(
                      b =>
                        `benchmark ${b.benchmark}: mean ${(b.mean_ns / 1000).toFixed(2)} us over ${b.iterations} iteration(s)`,
                    )
                    .join('\n')
                : '') +
              (s.coverageError ? `\nCoverage failed: ${s.coverageError}` : '') +
              (s.coverage ? `\nCoverage written to ${s.coverage}.` : ''),
          )
          .join('\n'),
  );
  if (summaries.some(s => !s.ok)) process.exitCode = 1;
}
// --report junit=path: one JUnit report merged across targets.
function parseReport(value)
{
  const match = value.match(/^junit=(.+)$/);
  if (!match) throw new Error('--report takes junit=<path>');
  return {kind: 'junit', path: match[1]};
}
// A run's JUnit XML: the runner's own where it writes one, otherwise made
// from what it printed.
async function junitOf(run, executed, root, since)
{
  if (run.report?.kind === 'junit')
  {
    const files =
      run.report.files ??
      (await readdir(path.join(root, run.report.directory)).catch(() => []))
        .filter(n => n.endsWith('.xml'))
        .map(n => path.join(root, run.report.directory, n));
    const xml = [];
    for (const file of files)
    {
      const info = await stat(path.resolve(root, file)).catch(() => null);
      if (info && info.mtimeMs >= since)
        xml.push(await readFile(path.resolve(root, file), 'utf8'));
    }
    return xml.join('\n');
  }
  // BEAM reports only executed cases. Intentional harness skips remain
  // reportable obligations; they are never evidence that a test passed.
  const skipped =
    run.report?.kind === 'beam-events'
      ? run.laws
          .filter(entry => entry.skip)
          .map(entry => ({
            name: entry.label,
            classname: entry.unit,
            status: 'skipped',
            reason: entry.skip,
          }))
      : [];
  return junitFromTests([...executed, ...skipped]);
}
// The tool --coverage needs, if it is missing.
async function coverageMissing(target, root, report)
{
  const tool = coverageTools[target.language];
  if (!tool)
    return {
      tool: 'a coverage tool',
      install: 'no coverage tool is known for this target',
    };
  const probe = (command, args) =>
    new Promise(resolve =>
    {
      const child = spawn(command, args, {cwd: root, stdio: 'ignore'});
      child.on('error', () => resolve(false));
      child.on('close', code => resolve(code === 0));
    });
  if (['erlang', 'elixir', 'gleam'].includes(target.language))
  {
    const requirement = beamCoverageRequirement(target, report);
    if (requirement) return requirement;
    return (await probe('erl', [
      '-noshell',
      '-eval',
      'case code:ensure_loaded(cover) of {module,cover} -> halt(0); _ -> halt(1) end.',
    ]))
      ? null
      : tool;
  }
  if (target.language === 'python')
    return (await probe(target.python || 'python3', tool.check)) ? null : tool;
  if (['javascript', 'typescript'].includes(target.language))
    return (await probe('npx', ['--no-install', 'c8', '--version']))
      ? null
      : tool;
  if (target.language === 'rust')
    return (await probe('cargo', ['llvm-cov', '--version'])) ? null : tool;
  if (target.language === 'kotlin')
  {
    const build = await readFile(
      path.join(root, 'build.gradle.kts'),
      'utf8',
    ).catch(() => '');
    return build.includes('kover') ? null : tool;
  }
  if (target.language === 'scala') return null;
  return null;
}
// Run a native test command, showing its output (on stderr with --json) and
// keeping it. Go's JSON events are shown as the text they carry.
function spawned(command, args, cwd, env, goJson = false)
{
  return new Promise((resolve, reject) =>
  {
    const child = spawn(command, args, {
      cwd,
      env,
      stdio: ['ignore', 'pipe', 'pipe'],
    });
    const shown = options.json ? process.stderr : process.stdout;
    let output = '';
    let pending = '';
    child.stdout.on('data', chunk =>
    {
      const text = chunk.toString();
      output += text;
      if (!goJson) return shown.write(text);
      pending += text;
      const lines = pending.split('\n');
      pending = lines.pop();
      for (const line of lines)
      {
        try
        {
          const event = JSON.parse(line);
          if (event.Output) shown.write(event.Output);
        }
        catch
        {
          shown.write(line + '\n');
        }
      }
    });
    child.stderr.on('data', chunk =>
    {
      output += chunk.toString();
      process.stderr.write(chunk);
    });
    child.on('error', reject);
    child.on('close', code => resolve({ok: code === 0, output}));
  });
}
async function readOptionalDirectory(folder)
{
  try
  {
    return await readdir(folder);
  }
  catch (error)
  {
    if (error.code === 'ENOENT') return null;
    throw error;
  }
}
async function main()
{
  if (options['machine-bits'] !== undefined)
  {
    options.machineBits = Number(options['machine-bits']);
    if (![32, 64].includes(options.machineBits))
      throw new Error('machineBits must be 32 or 64');
  }
  if (!verb || ['help', '--help', '-h'].includes(verb))
  {
    output(
      'LawSpec ' +
        VERSION +
        '\nUsage: lawspec prelude [query] [--json]\n       lawspec inspect --target <target> [--json]\n       lawspec advise [--target <target>] [--json] [--strict]\n       lawspec project init|adopt|status|validate [--project <directory>]\n       lawspec learn [--port <port>]\n       lawspec init --target <language> [--project <directory>] [--minify] [--no-install]\n       lawspec fmt [paths...] [--check] [--compile]\n       lawspec lsp --stdio | lawspec mcp\n       lawspec prove [--solver <z3-executable>] [--proof-timeout <ms>] [--json]\n       lawspec check [--warn-matches] [--no-advice] | doctor | explain [<unit>::<law>] [--view eng|math|dev] | generate\n       lawspec evidence [<unit> | <unit>::<declaration>] [--attestation <file>]\n       lawspec test [--target <language>] [--fresh] [--seed <n>] [--attestation <file>] [--update-recorded] [--tag <t>] [--exclude-tag <t>] [--report junit=<path>] [--coverage] [--benchmarks]\n       lawspec mutate [paths...] [--target <language>] [--mutation-timeout <ms>] [--json]\n       lawspec describe --json\n       lawspec fetch | update [<package>]\n       lawspec package [--project <package directory>] [--output <archive.tgz>]\n       lawspec examples [--example payments] [--target <language>] [--output <directory>]\nOptions: --config <path>, --target <language>, --machine-bits <32|64>, --json, --no-cache, --timings, --locked, --offline\nGeneration: --dry-run, --check, --minify\nTargets: ' +
        targets.join(', '),
    );
    return;
  }
  if (verb === '--version')
  {
    output(VERSION);
    return;
  }
  if (verb === 'prelude')
  {
    if (
      positional.length > 1 ||
      Object.keys(options).some(key => key !== 'json')
    )
      throw new Error('Usage: lawspec prelude [query] [--json]');
    const result = diagnostics(
      await (await createCompiler()).prelude({query: positional[0] ?? ''}),
    );
    return output(
      options.json
        ? result
        : result.entries
            .map(
              entry =>
                `${entry.kind}: ${entry.name}${entry.definition ? ` — ${entry.definition}` : ''}`,
            )
            .join('\n'),
    );
  }
  if (options.strict && verb !== 'advise')
    throw new Error('--strict applies to advise');
  if (options['no-advice'] && !['check', 'generate'].includes(verb))
    throw new Error('--no-advice applies to check and generate');
  if (verb === 'mutate')
  {
    const root = path.resolve(options.project ?? process.cwd());
    const report = await mutateProject({
      root,
      paths: positional,
      target: options.target,
      config: options.config ?? 'lawspec.edn',
      timeout: Number(options['mutation-timeout'] ?? 120000),
    });
    output(
      options.json
        ? report
        : report.mutations
            .map(
              row =>
                `${row.name}: ${row.status}${row.failedLaws.length ? ' (' + row.failedLaws.join(', ') + ')' : ''}`,
            )
            .join('\n') || `baseline: ${report.baseline.status}`,
    );
    if (!report.ok) process.exitCode = 1;
    return;
  }
  if (verb === 'learn')
  {
    if (positional.length || Object.keys(options).some(key => key !== 'port'))
      throw new Error('Usage: lawspec learn [--port <port>]');
    const {serveLearn} = await import('../learn.mjs');
    return serveLearn(options.port);
  }
  if (options.port !== undefined) throw new Error('--port applies to learn');
  if (verb === 'project')
  {
    if (
      positional.length !== 1 ||
      Object.keys(options).some(
        key => !['project', 'config', 'json', 'languages'].includes(key),
      )
    )
      throw new Error(
        'Usage: lawspec project init|adopt|status|validate [--project <directory>] [--json]; add targets with lawspec init --target',
      );
    const {setupProject, inspectProject, projectExitCode} =
      await import('../project.mjs');
    const action = positional[0];
    if (!['init', 'adopt', 'status', 'validate'].includes(action))
      throw new Error(
        'Usage: lawspec project init|adopt|status|validate [--project <directory>]',
      );
    if (options.config && options.project)
      throw new Error('Choose --config or --project');
    const root = options.config
      ? configRoot
      : path.resolve(options.project || '.');
    if (action === 'init' || action === 'adopt')
    {
      const result = await setupProject(root, {
        adopt: action === 'adopt',
        ...(options.languages ? {languages: options.languages.split(',')} : {}),
      });
      return output(
        options.json
          ? result
          : `LawSpec ${result.manifest}; Canon ${result.canon} in ${root}. Add an application with lawspec init --target <language>.`,
      );
    }
    if (options.languages)
      throw new Error('--languages applies to project init/adopt');
    const report = await inspectProject(root, {
      validate: action === 'validate',
      configFile: options.config ? configFile : path.join(root, 'lawspec.edn'),
    });
    output(
      options.json
        ? report
        : Object.entries(report)
            .filter(([key]) => key !== 'root')
            .map(([key, value]) => `${key}: ${JSON.stringify(value)}`)
            .join('\n'),
    );
    process.exitCode = projectExitCode(report);
    return;
  }
  if (options.languages)
    throw new Error('--languages applies to project init/adopt');
  if (options.compile && verb !== 'fmt')
    throw new Error('--compile applies to fmt');
  if (
    verb !== 'fmt' &&
    positional.length >
      (['project', 'explain', 'evidence', 'update'].includes(verb) ? 1 : 0)
  )
    throw new Error(`Unexpected argument: ${positional.join(' ')}`);
  if (verb === 'examples')
  {
    if (
      options.config ||
      options.project ||
      options['dry-run'] ||
      options.check
    )
      throw new Error(
        'examples supports --example, --target, --output, --machine-bits, --json and --minify only',
      );
    const result = await generateExamples(options);
    if (options.example)
    {
      output(
        options.json
          ? result
          : result
              .map(
                r =>
                  `${r.target}: payment project in ${r.directory}; ${r.preservedAdapters.length} user files preserved.` +
                  (r.adapterUpdates.length
                    ? `\nReview changed example files: ${r.adapterUpdates.map(a => a.path).join(', ')}`
                    : ''),
              )
              .join('\n') +
              "\nOpen each project's README.md, run lawspec generate, then its native test command.",
      );
      return;
    }
    output(
      options.json
        ? result
        : result
            .map(
              r =>
                `${r.target}: ${r.files.length} artifacts in ${r.directory}; ${r.preservedAdapters.length} user adapters preserved.${r.adapterUpdates.length ? '\nReview required adapter signatures:\n' + r.adapterUpdates.map(a => a.path + '\n' + a.requiredAdapter).join('\n') : ''}`,
            )
            .join('\n') +
            '\nInspection artifacts only; native toolchains and dependencies are not checked. Stubs must be implemented before running tests.',
    );
    return;
  }
  if (
    [
      'solver',
      'proof-timeout',
      'proof-memory',
      'proof-rlimit',
      'proof-seed',
    ].some(key => options[key] !== undefined) &&
    verb !== 'prove'
  )
    throw new Error('Z3 options apply to prove');
  if (options.view && verb !== 'explain')
    throw new Error('--view applies to explain');
  if (options.output && verb !== 'package')
    throw new Error('--output is only supported by examples and package');
  if (options.example)
    throw new Error('--example is only supported by examples');
  if (options['no-install'] && verb !== 'init')
    throw new Error('--no-install applies to init');
  if (
    options.minify &&
    !['init', 'generate', 'examples', 'test'].includes(verb)
  )
    throw new Error('--minify applies to init, generate, test and examples');
  if (
    (options.fresh ||
      options.seed !== undefined ||
      options.tag ||
      options['exclude-tag'] ||
      options.report !== undefined ||
      options.coverage ||
      options['update-recorded'] ||
      options.benchmarks) &&
    verb !== 'test'
  )
    throw new Error(
      '--fresh, --seed, --update-recorded, --tag, --exclude-tag, --report, --coverage and --benchmarks apply to test',
    );
  if (options.attestation !== undefined && !['evidence', 'test'].includes(verb))
    throw new Error('--attestation applies to evidence and test');
  if (options.seed !== undefined && !/^[0-9]+$/.test(options.seed))
    throw new Error('--seed must be a whole number');
  if (options['warn-matches'] && verb !== 'check')
    throw new Error('--warn-matches applies to check');
  if (options.stdio && verb !== 'lsp')
    throw new Error('--stdio applies to lsp');
  if (verb === 'lsp')
  {
    if (!options.stdio) throw new Error('lsp requires --stdio');
    return serveLanguage();
  }
  if (
    !options.config &&
    verb !== 'init' &&
    verb !== 'package' &&
    verb !== 'mcp' &&
    !(verb === 'fmt' && positional.length)
  )
  {
    configFile = await findManifest();
    configRoot = path.dirname(configFile);
  }
  if (verb === 'mcp')
  {
    if (options.target || options.project || options.output || options.stdio)
      throw new Error('mcp supports --config only');
    const {serveLawSpec} = await import('../mcp.mjs');
    return serveLawSpec(options.config ? configFile : undefined);
  }
  if (verb === 'describe')
    return output(await resolveComponent(configFile, options));
  if (verb === 'fetch' || verb === 'update')
  {
    const manifest = await readManifest(configFile);
    const resolved = await resolveDependencies(configFile, manifest, {
      ...options,
      update: verb === 'update' ? (positional[0] ?? true) : false,
    });
    return output(
      options.json
        ? resolved.lock
        : `Resolved ${resolved.packages.length} contract package(s).`,
    );
  }
  if (verb === 'fmt') return formatCommand();
  if (verb === 'init') return init();
  if (verb === 'package') return packageCommand();
  if (
    ![
      'check',
      'doctor',
      'evidence',
      'explain',
      'generate',
      'test',
      'prove',
      'inspect',
      'advise',
    ].includes(verb)
  )
    throw new Error(`Unknown command: ${verb}`);
  const config = await readManifest(configFile);
  config.targets ??= [];
  if (verb === 'inspect' && !options.target)
    throw new Error('inspect requires --target <target>');
  if (
    options.target &&
    !config.targets.some(t => t.language === options.target)
  )
    throw new Error('No matching configured target');
  if (verb === 'test' && artifactTargets.includes(options.target))
    throw new Error(
      `${options.target} is an artifact target and cannot execute application laws`,
    );
  const selected = config.targets.filter(
    t =>
      (!options.target || t.language === options.target) &&
      (verb !== 'test' || !artifactTargets.includes(t.language)),
  );
  if (
    ['doctor', 'generate', 'test', 'inspect'].includes(verb) &&
    !selected.length &&
    !(
      verb === 'test' &&
      !options.benchmarks &&
      config.manifestVersion === 1 &&
      !(config.verification?.layers ?? []).some(layer =>
        ['exhaustive', 'property', 'examples', 'model'].includes(layer),
      )
    )
  )
    throw new Error('No matching configured target');
  const roots = selected.map(t => path.resolve(configRoot, t.root));
  // A project's Gradle wrapper runs its tests too, not only its preparation.
  for (const [i, target] of selected.entries())
    if (['kotlin', 'groovy'].includes(target.language))
      target.gradle = await gradleFor(target, roots[i]);
  if (new Set(roots).size !== roots.length)
    throw new Error('Each configured target needs its own project root');
  if (verb === 'doctor')
  {
    const reports = await Promise.all(
      selected.map((t, i) => doctor(t, roots[i])),
    );
    // The project's own check: can the compiler keep its cache here?
    const location = cacheLocation({options, config, configRoot});
    if (location !== undefined)
      reports.push(await probeCache(location, await buildDigest()));
    output(
      options.json
        ? reports
        : reports
            .map(
              r =>
                `${r.target}: ${r.ok ? (r.detail ?? (r.kind === 'artifact' ? 'generation ready' : 'ready')) : `${r.message}\n${r.instructions}`}`,
            )
            .join('\n'),
    );
    if (reports.some(r => !r.ok)) process.exitCode = 1;
    return;
  }
  if (
    config.machineBits !== undefined &&
    ![32, 64].includes(config.machineBits)
  )
    throw new Error('machineBits must be 32 or 64');
  if (config.cache !== undefined && typeof config.cache !== 'boolean')
    throw new Error('cache must be true or false');
  if (
    config.cacheDirectory !== undefined &&
    (typeof config.cacheDirectory !== 'string' || !config.cacheDirectory)
  )
    throw new Error('cacheDirectory must be the path of a directory');
  if (
    config.attestation !== undefined &&
    typeof config.attestation !== 'string'
  )
    throw new Error(
      'attestation must be the path of an environment attestation',
    );
  // lawspec inspect and lawspec advise write nothing, so they keep no cache.
  const cache = ['inspect', 'advise'].includes(verb)
    ? undefined
    : await cacheDirectory(config);
  // The compiler reports its own progress on standard error: the running
  // stage on a terminal, and a table of every stage with --timings.
  const progress = [
    ...(options.timings ? ['timings'] : []),
    ...(process.stderr.isTTY && !options.json ? ['terminal'] : []),
  ];
  const input = {
    ...(cache === undefined ? {} : {cacheDirectory: cache}),
    ...(progress.length ? {progress} : {}),
    advice: !options['no-advice'],
    sources: await sources(config),
    languageProfile: config.languageProfile,
    verification: config.verification ?? {layers: []},
    ...(await packageInput(config, configRoot)),
    generation: config.generation,
    machineBits: options.machineBits ?? config.machineBits ?? 64,
    // What a law-set exemption's until is compared with: the project's
    // version and the current UTC time.
    ...((config.component?.version ?? config.package?.version)
      ? {projectVersion: config.component?.version ?? config.package?.version}
      : {}),
    now: new Date().toISOString(),
  };
  const compiler = reportingCache(await createCompiler());
  async function authoringReport()
  {
    const reports = [];
    for (const [i, target] of selected.entries())
    {
      let nativeSources;
      try
      {
        nativeSources = await collectNativeSources(roots[i]);
      }
      catch (error)
      {
        reports.push({
          findings: [],
          checks: [
            {
              rule: 'native-sources',
              status: 'incomplete',
              target: target.language,
              reason: error.message,
            },
          ],
          ok: false,
        });
        continue;
      }
      // This advice belongs to a command that keeps a cache, so it may use
      // it; lawspec advise and lawspec inspect have no cache directory.
      const advised = await compiler.advise({
        ...input,
        cacheAdvisory: true,
        target: target.language,
        sourceDir: target.sourceDir,
        testDir: target.testDir,
        nativeBindings: target.nativeBindings,
        actors: target.actors,
        nativeSources,
        exceptions: config.authoringExceptions ?? [],
      });
      if (advised.diagnostics?.length)
        reports.push({
          findings: [],
          checks: [
            {
              rule: 'native-interface',
              target: target.language,
              status: 'incomplete',
              reason: advised.diagnostics.map(d => d.message).join('; '),
            },
          ],
          ok: false,
        });
      else reports.push(advised.advice);
    }
    if (!selected.length)
      reports.push(
        diagnostics(
          await compiler.advise({
            ...input,
            exceptions: config.authoringExceptions ?? [],
          }),
        ).advice,
      );
    const unique = rows => [
      ...new Map(rows.map(row => [JSON.stringify(row), row])).values(),
    ];
    return settleAdvice(
      {
        findings: unique(reports.flatMap(r => r.findings)),
        checks: unique(reports.flatMap(r => r.checks)),
      },
      config.authoringExceptions ?? [],
    );
  }
  function printAdvice(report)
  {
    for (const finding of report.findings.filter(
      f => f.status === 'unresolved',
    ))
      console.error(
        `warning ${finding.rule}: ${finding.declaration}: ${finding.message}`,
      );
    for (const check of report.checks.filter(
      c => !['complete', 'not-applicable'].includes(c.status),
    ))
      console.error(
        `advice ${check.status}: ${check.declaration ?? check.path ?? check.target ?? 'source'}: ${check.reason}`,
      );
  }
  if (verb === 'inspect')
  {
    const target = selected[0];
    const result = diagnostics(
      await compiler.inspect({
        ...input,
        target: target.language,
        sourceDir: target.sourceDir,
        testDir: target.testDir,
        nativeBindings: target.nativeBindings,
        actors: target.actors,
      }),
    );
    return output(options.json ? result : result.interface);
  }
  if (verb === 'advise')
  {
    diagnostics(await compiler.check({...input, advice: false}));
    const report = await authoringReport();
    if (options.json) output(report);
    else
    {
      printAdvice(report);
      output(
        report.ok
          ? 'Selected authoring checks complete; no unresolved findings.'
          : 'Authoring review required; see findings and analysis limits.',
      );
    }
    if (options.strict && !report.ok) process.exitCode = 1;
    return;
  }
  if (verb === 'prove')
  {
    const result = diagnostics(
      await proveWithZ3(compiler, input, {
        ...(options.solver !== undefined ? {binary: options.solver} : {}),
        ...Object.fromEntries(
          [
            ['proof-timeout', 'timeoutMs'],
            ['proof-memory', 'memoryMb'],
            ['proof-rlimit', 'resourceLimit'],
            ['proof-seed', 'seed'],
          ]
            .filter(([name]) => options[name] !== undefined)
            .map(([name, key]) => [key, Number(options[name])]),
        ),
      }),
    );
    output(
      options.json
        ? result
        : result.solverEvidence.length
          ? result.solverEvidence
              .map(
                row =>
                  `${row.declaration}${row.kind === 'analysis' ? ` ${row.stage}` : ''}: ${row.status} (${row.outcome}). ${row.reason}`,
              )
              .join('\n')
          : input.verification?.layers.includes('proof')
            ? 'No source law obligations are available. No solver was invoked.'
            : 'No proof layer selected. Intrinsic definition checks passed; no solver was invoked.',
    );
    // A refuted law is a definite failure; anything else not proved is incomplete.
    if (result.solverEvidence.some(row => row.status === 'refuted'))
      process.exitCode = 1;
    else if (
      result.solverEvidence.some(
        row => !['proved', 'exempted'].includes(row.status),
      )
    )
      process.exitCode = 2;
    return;
  }
  // Each obligation reports how it is discharged, strongest first.
  const statuses = [
    ['proved', 'PROVED'],
    ['exhaustively-checked', 'EXHAUSTIVELY CHECKED'],
    ['property-tested', 'PROPERTY TESTED'],
    ['measured', 'MEASURED'],
    ['runtime-checked', 'RUNTIME CHECKED'],
    ['default-handler', 'DEFAULT HANDLER'],
    ['assumed', 'ASSUMED / EXTERNAL'],
    // A law-set check a laws-for block excuses, with its reason and expiry.
    ['exempted', 'EXEMPTED'],
    // A law a confirmed counterexample shows false; the build fails.
    ['refuted', 'REFUTED'],
    // The harness plane: an acknowledged discrepancy, a law whose last
    // run was flaky, and a law whose tests it skips.
    ['known-discrepancy', 'KNOWN DISCREPANCY'],
    ['flaky', 'FLAKY'],
    ['skipped', 'SKIPPED'],
    // A law about an open history that the entries so far do not decide.
    ['pending', 'PENDING'],
    ['planned', 'PLANNED'],
    ['not-verified', 'NOT VERIFIED'],
    ['incomplete', 'INCOMPLETE'],
    ['unsupported', 'UNSUPPORTED'],
  ];
  const evidenceSummary = evidence =>
  {
    if (!evidence.length) return '';
    const count = status =>
      evidence.filter(item => item.status === status).length;
    // Exempted, refuted and the harness statuses (after assumed) are counted only when
    // some obligation has them.
    const harnessFrom = statuses.findIndex(([status]) => status === 'exempted');
    const shown = statuses.filter(
      ([status], i) => i < harnessFrom || count(status),
    );
    return ` Evidence: ${shown.map(([status, label]) => `${count(status)} ${label.toLowerCase()}`).join(', ')}.`;
  };
  const obligationName = item => item.declaration.replace('::law::', '::');
  if (verb === 'check')
  {
    const result = diagnostics(
      await compiler.check({
        ...input,
        ...(options['warn-matches'] ? {warnMatches: true} : {}),
      }),
    );
    if (!options['no-advice'])
    {
      result.advice = await authoringReport();
      if (!options.json) printAdvice(result.advice);
    }

    for (const target of selected)
    {
      if (target.nativeBindings !== undefined)
        diagnostics(
          await compiler.check({
            ...input,
            nativeBindings: target.nativeBindings,
            actors: target.actors,
          }),
        );
    }
    output(
      options.json
        ? result
        : `Compiled ${result.laws.length} law(s). Intrinsic definition checks passed.` +
            (result.verification?.selection === 'no-selected-checks'
              ? ' No law checks selected.'
              : evidenceSummary(result.evidence ?? [])),
    );
    return;
  }
  if (verb === 'evidence')
  {
    // An attestation named here, or in lawspec.edn, says where the tests
    // ran; otherwise each law shows the attested run it last passed in.
    // A named attestation of a run lawspec test recorded links each law to
    // that run, with the outcome recorded for it, unless the document says
    // the run has not completed.
    const named = await readAttestation(config);
    const {runs, attestations, outcomes} = await lastRuns();
    const recorded =
      named && typeof named.run?.id === 'string'
        ? outcomes.get(named.run.id)
        : undefined;
    const result = diagnostics(
      refutedOnly(
        await compiler.check({
          ...input,
          ...(named
            ? {
                attestation: named,
                ...(recorded ? {attestedOutcomes: recorded} : {}),
              }
            : {}),
        }),
      ),
    );
    if (result.refuted) process.exitCode = 1;
    let evidence = attachNativeEvidence(
      result.evidence,
      await readNativeObservations({
        compiler,
        input,
        selected,
        roots,
        configRoot,
        config,
        build: await buildDigest(),
        evidence: result.evidence,
        attestation: named,
      }),
    );
    const environments = named ? [result.attestation] : [];
    if (!named)
      for (const [id, attestation] of attestations)
      {
        const laws = new Set(
          [...runs]
            .filter(([, run]) => run.environment === id)
            .map(([law]) => law),
        );
        if (!laws.size) continue;
        const attested = diagnostics(
          await compiler.check({
            ...input,
            attestation,
            attestedOutcomes: outcomes.get(id) ?? {},
          }),
        );
        const fields = new Map(
          attested.evidence
            .filter(
              item =>
                (item.against || item.plannedAgainst) &&
                laws.has(item.declaration),
            )
            .map(item =>
            {
              // Receipts predating execution states keep their historical meaning.
              // An explicit running/wired state must retain the compiler's planned
              // fields; a cached passing law does not complete its environment run.
              const legacy = !attestation.execution && !item.against;
              return [
                item.declaration,
                legacy
                  ? {
                      environment: item.plannedEnvironment,
                      environmentRun: item.plannedEnvironmentRun,
                      against: item.plannedAgainst,
                      environmentProviders: item.plannedEnvironmentProviders,
                    }
                  : Object.fromEntries(
                      [
                        'environment',
                        'environmentRun',
                        'against',
                        'environmentProviders',
                        'environmentOutcome',
                        'plannedEnvironment',
                        'plannedEnvironmentRun',
                        'plannedAgainst',
                        'plannedEnvironmentProviders',
                      ]
                        .filter(key => item[key] !== undefined)
                        .map(key => [key, item[key]]),
                    ),
              ];
            }),
        );
        evidence = evidence.map(item =>
          item.stage === 'law' && fields.has(item.declaration)
            ? {...item, ...fields.get(item.declaration)}
            : item,
        );
        environments.push({
          ...attested.attestation,
          dependencies: attested.attestation.dependencies.map(d => ({
            ...d,
            obligations: (attestation.execution
              ? d.obligations
              : [
                  ...new Set([
                    ...d.obligations,
                    ...(d.plannedObligations ?? []),
                  ]),
                ]
            ).filter(law => laws.has(law)),
            plannedObligations: attestation.execution
              ? (d.plannedObligations ?? []).filter(law => laws.has(law))
              : [],
          })),
        });
      }
    // Native bindings are configured per target; their obligations are added.
    for (const target of selected)
    {
      if (target.nativeBindings === undefined) continue;
      const bound = diagnostics(
        await compiler.check({...input, nativeBindings: target.nativeBindings}),
      );
      evidence = evidence.concat(
        bound.evidence
          .filter(item =>
            ['binding', 'codec', 'generator', 'native-function'].includes(
              item.stage,
            ),
          )
          .map(item => ({...item, target: target.language})),
      );
    }
    evidence = evidence.filter(
      item =>
        !positional[0] ||
        obligationName(item) === positional[0] ||
        item.owner === positional[0],
    );
    if (positional[0] && !evidence.length)
      throw new Error('No matching obligation');
    // The last run's outcome (lawspec test): a law that failed, then passed
    // on a retry, is flaky; what its generated cases covered is its adequacy.
    evidence = evidence.map(item =>
    {
      if (item.nativeEvidence) return item;
      const run = item.stage === 'law' ? runs.get(item.declaration) : undefined;
      if (!run) return item;
      return {
        ...item,
        lastNativeRun: {passed: run.passed, seed: run.seed},
        ...(run.adequacy ? {adequacy: run.adequacy} : {}),
        ...(run.flaky &&
        ['property-tested', 'exhaustively-checked'].includes(item.status)
          ? {
              status: 'flaky',
              reason: `${item.reason}; its last run failed, then passed on a retry`,
            }
          : {}),
      };
    });
    const harnessed = evidence.filter(item => item.harness || item.adequacy);
    output(
      options.json
        ? evidence
        : [
            ...statuses
              .map(([status, label]) =>
                {
                const items = evidence.filter(item => item.status === status);
                if (!items.length) return null;
                return (
                  `${label} (${items.length})\n` +
                  items
                    .map(
                      item =>
                        `  ${item.stage} ${obligationName(item)}${item.target ? ` [${item.target}]` : ''}` +
                        (item.claim ? `: ${item.claim.text}` : '') +
                        `\n    ${item.reason}` +
                        (item.nativeEvidence
                          ? `\n    ${nativeEvidenceText(item).replaceAll('\n', '\n    ')}`
                          : '') +
                        (item.lastNativeRun
                          ? `\n    last native run passed at ${item.lastNativeRun.passed} (seed ${item.lastNativeRun.seed})`
                          : '') +
                        (item.against
                          ? (item.environmentOutcome
                              ? `\n    ${item.environmentOutcome} in completed run ${item.environmentRun.id} in environment ${item.environment}${executionText(item.environmentRun)} against `
                              : `\n    last recorded passing run in environment ${item.environment} (run ${item.environmentRun.id}) against `) +
                            item.against.map(dependencyText).join('; ')
                          : '') +
                        (item.plannedAgainst
                          ? `\n    planned in environment ${item.plannedEnvironment} (run ${item.plannedEnvironmentRun.id}` +
                            `${executionText(item.plannedEnvironmentRun)}; ${unlinkedText(item.plannedEnvironmentRun)}) against ` +
                            item.plannedAgainst.map(dependencyText).join('; ')
                          : ''),
                    )
                    .join('\n')
                );
              })
              .filter(section => section !== null),
            // How each law is discharged: the harness plane, apart from what
            // the laws say.
            ...(harnessed.length
              ? [
                  `HARNESS (${harnessed.length})\n` +
                    harnessed.map(harnessText).join('\n'),
                ]
              : []),
            // Where the tests ran: reporting only, so no status above changes.
            ...environments.map(
              e =>
                `ENVIRONMENT ${e.environment} (run ${e.run.id}, recorded ${e.run.recordedAt}${executionText(e.run)})\n` +
                (e.architecture
                  ? `  architecture ${e.architecture.document} ${e.architecture.digest}` +
                    (e.architecture.topologyDigest
                      ? `, topology ${e.architecture.topologyDigest}`
                      : '') +
                    '\n'
                  : '') +
                (e.application
                  ? `  application ${e.application.node}: ` +
                    (e.application.component
                      ? `component ${e.application.component.name} ${e.application.component.version} (${e.application.component.fingerprint}); `
                      : `contract ${e.application.contract.package} ${e.application.contract.version}; `) +
                    `${e.application.implementation.kind} ${e.application.implementation.product} ${e.application.implementation.version}` +
                    (e.application.implementation.commit
                      ? ` (commit ${e.application.implementation.commit})`
                      : '') +
                    '\n'
                  : '') +
                e.dependencies
                  .map(d =>
                    {
                    const outcome = o =>
                      evidence.find(
                        item =>
                          item.declaration === o && item.environmentOutcome,
                      )?.environmentOutcome;
                    const failed = d.obligations.filter(o =>
                      ['failed', 'incomplete'].includes(outcome(o)),
                    ).length;
                    return (
                      `  ${dependencyText(d)}; ` +
                      (d.obligations.length
                        ? `${d.obligations.length} tested obligation(s)` +
                          (failed ? `, ${failed} failed` : '')
                        : d.plannedObligations?.length
                          ? `${d.plannedObligations.length} planned obligation(s); ${unlinkedText(e.run)}`
                          : 'no tested obligation relies on it')
                    );
                  })
                  .join('\n'),
            ),
          ].join('\n\n'),
    );
    return;
  }
  if (verb === 'explain')
  {
    // The compiler words the law (eng by default); the CLI only reads the
    // recorded native observations and passes their evidence rows in.
    const request = {
      ...input,
      view: options.view ?? 'eng',
      ...(positional[0] ? {law: positional[0]} : {}),
    };
    let explained = diagnostics(await compiler.explain(request));
    const expanded = diagnostics(await compiler.expand(input));
    const observations = await readNativeObservations({
      compiler,
      input,
      selected,
      roots,
      configRoot,
      config,
      build: await buildDigest(),
      evidence: expanded.evidence,
      attestation: await readAttestation(config),
    });
    if (observations.length)
      explained = diagnostics(
        await compiler.explain({
          ...request,
          evidence: attachNativeEvidence(expanded.evidence, observations),
        }),
      );
    output(options.json ? explained.explanations : explained.text);
    return;
  }
  if (
    verb === 'test' &&
    !options.benchmarks &&
    config.manifestVersion === 1 &&
    !(config.verification?.layers ?? []).some(layer =>
      ['exhaustive', 'property', 'examples', 'model'].includes(layer),
    )
  )
  {
    const checked = diagnostics(await compiler.check(input));
    output(
      options.json
        ? {
            verification: checked.verification,
            evidence: checked.evidence,
            testsExecuted: 0,
          }
        : config.verification?.layers?.length
          ? 'No native law checks selected. See lawspec evidence for the selected static analyses.'
          : 'No law verification layers selected. Intrinsic definition checks passed; no law checks ran.',
    );
    return;
  }
  if (verb === 'test')
    return runTests(compiler, input, selected, roots, config);
  if (options['dry-run'] && options.check)
    throw new Error('--dry-run and --check are mutually exclusive');
  const advisory = options['no-advice'] ? undefined : await authoringReport();
  if (advisory && !options.json) printAdvice(advisory);
  const artifacts = [];
  for (const target of selected)
    artifacts.push(
      diagnostics(
        await compiler.planGeneration({
          ...input,
          target: target.language,
          sourceDir: target.sourceDir,
          testDir: target.testDir,
          nativeBindings: target.nativeBindings,
          actors: target.actors,
          minify: options.minify === true,
        }),
      ).files,
    );
  const reports = await Promise.all(
    selected.map((t, i) => doctor(t, roots[i], artifacts[i])),
  );
  const failed = reports.filter(r => !r.ok);
  if (failed.length)
    throw new Error(
      failed
        .map(r => `${r.target}: ${r.message}\n${r.instructions}`)
        .join('\n'),
    );
  const plans = await Promise.all(
    artifacts.map((files, i) => planWrites(roots[i], files)),
  );
  if (!options['dry-run'] && !options.check) await applyWrites(plans);
  const summary = plans.map((plan, i) => ({
    target: selected[i].language,
    ...(advisory ? {advice: advisory} : {}),
    changes: plan.changes.map(c => ({action: c.action, path: c.relative})),
    preservedAdapters: plan.preserved,
    adapterUpdates: plan.adapterUpdates,
    test: testCommand(selected[i], roots[i]),
  }));
  output(
    options.json
      ? summary
      : summary
          .map(
            r =>
              `${r.target}: ${r.changes.length} ${options['dry-run'] || options.check ? 'planned' : 'applied'} change(s), ${r.preservedAdapters.length} user adapter(s) preserved.${r.adapterUpdates.length ? '\nReview required adapter signatures:\n' + r.adapterUpdates.map(a => a.path + '\n' + a.requiredAdapter).join('\n') : ''}\n${r.test === null ? 'Artifact generation complete.' : 'Test: ' + r.test}`,
          )
          .join('\n'),
  );
  if (options.check && plans.some(p => p.changes.length)) process.exitCode = 1;
}
main().catch(async error =>
{
  if (createdState !== null)
    await rm(createdState, {recursive: true, force: true});
  if (options.json)
    output({
      diagnostics: error.diagnostics || [
        {code: 'cli', message: error.message, at: null},
      ],
    });
  else console.error(`lawspec: ${error.message}`);
  process.exitCode = 1;
});
