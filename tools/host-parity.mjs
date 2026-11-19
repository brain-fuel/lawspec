// Generated from templates/tools/host-parity.mjs by lawspec-dev generate. Do not edit.
// Host parity: the behaviour-equivalence corpus of the Haskell application
// port. Each case runs, in its own fresh project, under the native CLI
// (lawspec-native, the reference: the core over the native-IO interpreter),
// the npm package's CLI (the Node Worker host over the host-effect core),
// with --go, the Go host's CLI and, with --jvm, the JVM launcher (java -jar
// over the platform jar's lawspec-native, which checks the launcher's
// passthrough). stdout, stderr, the exit code and every resulting file must
// be byte-identical. Until 0.36.0 the reference was the legacy Node CLI,
// which every case matched before it was removed.
// Usage: node tools/host-parity.mjs --native <lawspec-native> --core <core.wasm>
//   [--go <Go host lawspec>] [--jvm <launcher jar>] [--canon <bundle>]
//   [--only <patterns>] [--jobs <n>]
// --canon names the Canon bundle (tools/build-canon.sh) the native CLI and
// the Go host run for lawspec project, as LAWSPEC_CANON; the JVM launcher
// runs the one its platform jar carries, and the npm CLI, which finds no
// @goforgedev/canon-<platform> package in the checkout, the ricestax package
// (its route on a platform with no native Canon). Every Canon then has to
// answer as ricestax@0.4.3's does.
// --only (or LAWSPEC_PARITY_ONLY) selects cases by name: a comma-separated
// list of patterns, each a glob over the whole name (* any run of
// characters, ? one) or, without either, a prefix of it. --jobs (or
// LAWSPEC_PARITY_JOBS) bounds how many runs go at once; the default is the
// available parallelism, at most eight. Each run has its own project root,
// so runs share nothing they write but the toolchains' own caches, which
// are safe for concurrent use (Go's build cache, wazero's compilation
// cache, which is filled once before the runs). Results are reported in
// case order, whatever order the runs finish in.
// ref:DEC-host-effect-abi ref:DEC-haskell-application-port
import {execFileSync, spawn, spawnSync} from 'node:child_process';
import {createHash} from 'node:crypto';
import {
  chmodSync,
  cpSync,
  lstatSync,
  mkdirSync,
  mkdtempSync,
  readFileSync,
  readdirSync,
  realpathSync,
  rmSync,
  writeFileSync,
} from 'node:fs';
import http from 'node:http';
import net from 'node:net';
import os from 'node:os';
import path from 'node:path';
import {fileURLToPath} from 'node:url';
import {gunzipSync} from 'node:zlib';

const repository = path.resolve(fileURLToPath(import.meta.url), '../..');
const option = (name, required = true) =>
{
  const index = process.argv.indexOf(name);
  if (index < 0 || !process.argv[index + 1])
  {
    if (!required)
    {
      return null;
    }
    throw new Error(`missing ${name}`);
  }
  return process.argv[index + 1];
};
const native = path.resolve(option('--native'));
const core = path.resolve(option('--core'));
const goHost = option('--go', false);
const jvmHost = option('--jvm', false);
const canonBundle = option('--canon', false);
const only = option('--only', false) ?? process.env.LAWSPEC_PARITY_ONLY ?? '';
const jobsText =
  option('--jobs', false) ?? process.env.LAWSPEC_PARITY_JOBS ?? '';
const jobs =
  jobsText === '' ? Math.min(os.availableParallelism(), 8) : Number(jobsText);
if (!Number.isInteger(jobs) || jobs < 1)
{
  throw new Error(`--jobs must be a whole number above 0, not ${jobsText}`);
}
// A pattern with * or ? is a glob over the whole name; any other is a
// prefix of it.
const patterns = only
  .split(',')
  .map(pattern => pattern.trim())
  .filter(pattern => pattern !== '')
  .map(pattern =>
    /[*?]/.test(pattern)
      ? new RegExp(
          `^${pattern
            .split('')
            .map(character =>
              character === '*'
                ? '.*'
                : character === '?'
                  ? '.'
                  : character.replace(/[.+^${}()|[\]\\]/g, '\\$&'),
            )
            .join('')}$`,
        )
      : {test: name => name.startsWith(pattern)},
  );
const selects = name =>
  patterns.length === 0 || patterns.some(pattern => pattern.test(name));

// The package resources lawspec learn serves: the native CLI and the Go
// host ship none, so they are pointed at the checkout's npm package, which
// the npm CLI serves by default.
const resources = {
  LAWSPEC_RESOURCES: path.join(repository, 'npm'),
  ...(canonBundle === null ? {} : {LAWSPEC_CANON: path.resolve(canonBundle)}),
};
// The runtime's experimental-feature notice names the process id; it is
// Node's, not the CLI's, so it is switched off. The npm CLI finds Canon
// through the ricestax package (above).
const nodeEnvironment = {...process.env, NODE_NO_WARNINGS: '1'};
delete nodeEnvironment.LAWSPEC_CANON;
const runners = {
  native: arguments_ => [native, arguments_, {...process.env, ...resources}],
  'node-host': arguments_ => [
    process.execPath,
    [path.join(repository, 'npm/bin/lawspec.mjs'), ...arguments_],
    {...nodeEnvironment, LAWSPEC_HOST_CORE: core},
  ],
};
// The Go host runs the same core as the Node host: a release downloads its
// pinned core, so a checkout names the one it built.
if (goHost !== null)
{
  runners['go-host'] = arguments_ => [
    path.resolve(goHost),
    arguments_,
    {...process.env, ...resources, LAWSPEC_HOST_CORE: core},
  ];
}
// The JVM launcher finds its platform and resources jars beside it, as
// java -jar does after mvn dependency:copy, and unpacks them into one cache
// for every run. It serves learn from the resources jar it ships, so it is
// not pointed at npm/.
if (jvmHost !== null)
{
  const jvmEnvironment = {...process.env};
  delete jvmEnvironment.LAWSPEC_RESOURCES;
  delete jvmEnvironment.LAWSPEC_CANON;
  jvmEnvironment.LAWSPEC_JVM_CACHE = path.join(
    path.dirname(path.resolve(jvmHost)),
    'cache',
  );
  // By its path: some cases run with a PATH that has no java on it, which
  // the launcher passes through to lawspec.
  const java = execFileSync('/usr/bin/which', ['java'], {
    stdio: ['ignore', 'pipe', 'ignore'],
  })
    .toString()
    .trim();
  runners['jvm-host'] = arguments_ => [
    java,
    ['-jar', path.resolve(jvmHost), ...arguments_],
    jvmEnvironment,
  ];
}

// The toolchains some cases need, by their real paths (the core records a
// solver's real path). A case whose toolchain is absent is
// skipped and reported as skipped, never as passing.
const toolchain = name =>
{
  try
  {
    return realpathSync(
      execFileSync('/usr/bin/which', [name], {
        stdio: ['ignore', 'pipe', 'ignore'],
      })
        .toString()
        .trim(),
    );
  }
  catch
  {
    return null;
  }
};
const tools = {z3: toolchain('z3'), go: toolchain('go'), git: toolchain('git')};
// A solver's wall-clock time differs between any two runs, in indented
// JSON and in the compact rows lawspec project prints.
const withoutTimes = text =>
  text.replace(/"elapsedMs": ?[0-9.e+-]+/g, '"elapsedMs": 0');
// The seed lawspec test picks when none is given.
const withoutSeeds = text => text.replace(/"seed": ?[0-9]+/g, '"seed": 0');
// What a native test run prints and records that differs between any two
// runs: go test's and Rapid's timings, go test -json's event times, a
// panic's addresses and goroutine numbers, and when each attempt ran.
const withoutRunTimes = text =>
  text
    .replace(/(\t|\\t)[0-9.]+s\b/g, '$1<s>')
    .replace(/\([0-9.]+(?:s|ms|µs|ns)\)/g, '(<s>)')
    .replace(/\\"Time\\":\\"[^\\]*\\"/g, '\\"Time\\":\\"<time>\\"')
    .replace(/\\"Elapsed\\":[0-9.]+/g, '\\"Elapsed\\":0')
    .replace(/0x[0-9a-f]+/g, '0x')
    .replace(/goroutine \d+/g, 'goroutine <n>')
    .replace(/"(at|passed|failed)": "\d{4}-\d\d-\d\dT[^"]*"/g, '"$1": "<time>"')
    .replace(/"time": [0-9.e+-]+/g, '"time": 0')
    .replace(/ time="[0-9.]+"/g, ' time="0"');
// What lawspec evidence and lawspec explain show of a recorded native
// attempt that differs between runs and runners: its result key and the
// core's build digest (keyed by the host that ran the core, by design), and
// when it ran, in text as well as in JSON, with the go test -json events
// of a failed invocation's output as text shows them.
const withoutObservedRuns = text =>
  withoutRunTimes(withoutSeeds(text))
    .replace(/"Time":"[^"]*"/g, '"Time":"<time>"')
    .replace(/"Elapsed":[0-9.]+/g, '"Elapsed":0')
    .replace(/"(key|build)": "[0-9a-f]{64}"/g, '"$1": "<digest>"')
    .replace(/\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d(?:\.\d+)?Z/g, '<time>');
// The results of lawspec test, named by the project's path (a fresh
// temporary root per run), and keyed by the host that ran the core: the
// core names its host (kind, version, core digest), so a result key, the
// presentation digest that covers the environment and the build digest
// differ between the reference and each host by design. Only where they appear is compared.
const testResults = (name, content, root) =>
{
  const file = name.replace(
    /^(\.lawspec\/(?:results\/[a-z0-9]+-|failures\/[a-z0-9]+\/|reports\/[a-z0-9]+\/|coverage\/[a-z0-9]+\/))[0-9a-f]{12}/,
    '$1<project>',
  );
  return [
    file,
    file === name && !name.endsWith('.xml')
      ? content
      : Buffer.from(
          withoutRunTimes(
            content.toString().replaceAll(root, '<root>'),
          ).replace(
            /"(key|build|presentation)": "[0-9a-f]{64}"/g,
            '"$1": "<digest>"',
          ),
        ),
  ];
};

// A source the parser rejects.
const broken = 'unit broken\nf :: \nend unit\n';
// lawspec init's starter for an artifact target.
const configuration =
  'unit configuration\ntype Settings is a record{port :: UInt16 enabled :: Bool} end type\nfunction settings (unused :: Unit) -> Settings is Settings record{port = 8080, enabled = true} end function\nend unit\n';
const layers =
  ':verification {:layers [:proof :exhaustive :property :examples :runtime :model]}';
const manifest = (fields, name = 'specs') =>
  `{\n  :manifest-version 1\n  :component {:name "${name}" :version "0.1.0"}\n  :language-profile "1.0-rc.2"\n  :sources ["laws"]\n${fields}\n}\n`;
const specsManifest = manifest(`  :targets []\n  ${layers}`);
const artifactManifest = manifest(
  '  :targets [{:language :hcl :root "hcl"} {:language :yaml :root "yaml"} {:language :make :root "make"} {:language :antlr4 :root "antlr"}]\n  :verification {:layers []}',
  'artifacts',
);
const specFiles = [
  'atoi_codec',
  'boolean_flags',
  'abilities',
  'algebra',
  'approvals',
  'actors',
];
// Specifications Z3 settles quickly: proved, unsupported and incomplete laws.
const proofFiles = [
  'refined_definitions',
  'finite_data',
  'keywords',
  'consistency',
];
// A law Z3 refutes, with a counterexample the evaluator confirms.
const wrongLaw =
  'unit example.wrong\nfunction double (x :: Integer) -> Integer is\n  x + x\nend function\nlaw "|double is square| is\n  definition : for all (x :: Integer) => double x = x * x end for all end definition\nend law\nend unit\n';

// lawspec evidence over environment attestations (evidence.test.mjs): an
// ability a stand-in provides, a real dependency, and a law neither touches.
const attestedSpec =
  'unit shop.orders\n\ntype Receipt is a record{cents :: Int32} end type\nability Gateway is\n  capture :: Int32 -> Receipt\nend ability\nnormalize :: Int32 -> Int32\nfunction twice (x :: Int32) -> Integer is x + x end function\nprocedure checkout (cents :: Int32) -> Bool uses Gateway is\n  first matching case of capture cents:\n    when Receipt record{cents = paid} then paid = cents\n  end case\nend procedure\n\nlaw checkoutCharges is\n  definition: for all (cents :: Int32) => checkout cents = true end for all end definition\nend law\nlaw normalizing is\n  definition: for all (x :: Int32) => normalize (normalize x) = normalize x end for all end definition\nend law\nlaw doubling is\n  definition: for all (x :: Int32) => twice x = x * 2 end for all end definition\nend law\n\nend unit\n';
// A false law over a finite domain, which check itself refutes.
const refutedLaw =
  'unit shop.refuted\n\nfunction inc (x :: Int8) -> Integer is x + 1 end function\nlaw alwaysPositive is definition: for all (x :: Int8) => inc x > 0 end for all end definition end law\n\nend unit\n';
const attestationDocument = (
  id,
  gateway = {
    kind: 'stand-in',
    stand_in: {product: 'acme/gateway', version: '0.1.0', conformance: '3'},
  },
) => ({
  format: 'environment-attestation',
  version: 1,
  environment: 'staging',
  run: {
    id,
    started_at: '2026-10-09T19:30:31Z',
    recorded_at: '2026-10-09T19:30:33Z',
  },
  dependencies: [
    {
      name: 'shop.orders::Gateway',
      endpoint: 'localhost:9092',
      reached: true,
      ...gateway,
    },
    {
      name: 'shop.orders::normalize',
      endpoint: 'https://normalize.example.com',
      reached: true,
      kind: 'real',
    },
    {
      name: 'payments',
      endpoint: 'https://payments.example.com',
      reached: false,
      kind: 'real',
    },
  ],
});
// A run's document with what its execution recorded: an architecture, the
// application, and a stand-in with a contract, a node and histories.
const executedDocument = (id, execution) =>
{
  const contract = {package: 'acme/gateway-contract', version: '1.0.0'};
  const base = attestationDocument(id, {
    kind: 'stand-in',
    node: 'gateway',
    contract,
    implementation: {
      kind: 'fixture',
      product: 'acme/gateway',
      version: '0.1.0',
    },
    completed: {reached: true, history_digest: 'sha256:' + 'b'.repeat(64)},
    stand_in: {
      product: 'acme/gateway',
      version: '0.1.0',
      conformance: '3',
      history_digest: 'sha256:' + 'a'.repeat(64),
      stands_in_for: contract,
    },
  });
  return {
    ...base,
    execution,
    architecture: {
      document: 'shop.calm.json',
      digest: 'sha256:' + 'c'.repeat(64),
      topology_digest: 'sha256:' + 'd'.repeat(64),
    },
    application: {
      node: 'shop',
      contract: {package: 'shop', version: '1.0.0'},
      implementation: {
        kind: 'application',
        product: 'shop',
        version: '1.2.0',
        commit: 'abc123',
      },
    },
    dependencies: base.dependencies.map(d =>
      d.kind === 'real'
        ? {
            ...d,
            implementation: {
              kind: 'real-provider',
              product: d.name,
              version: '1',
            },
          }
        : d,
    ),
  };
};
// Results as lawspec test --attestation records them, under a project key
// no configured target has: only the attested runs are read from them.
const attestedResults = record => ({
  '.lawspec/results/javascript-000000000000.json': JSON.stringify({
    version: 1,
    ...record,
  }),
});
const passedIn = environment => ({
  key: 'k',
  seed: 1,
  passed: '2026-10-09T19:31:00.000Z',
  ...(environment ? {environment} : {}),
});

// Each fixture builds a fresh project in an empty directory and returns the
// working directory its invocations start in.
const fixtures = {
  // examples/specs as it is, with a text file (the fmt cases).
  flat: root =>
  {
    cpSync(path.join(repository, 'examples/specs'), root, {
      recursive: true,
      filter: source =>
        source === path.join(repository, 'examples/specs') ||
        source.endsWith('.lawspec'),
    });
    cpSync(path.join(repository, 'LICENSE'), path.join(root, 'README.txt'));
    return root;
  },
  // A component with six of examples/specs, every layer and no targets.
  specs: root =>
  {
    mkdirSync(path.join(root, 'laws'));
    for (const name of specFiles)
    {
      cpSync(
        path.join(repository, 'examples/specs', `${name}.lawspec`),
        path.join(root, 'laws', `${name}.lawspec`),
      );
    }
    writeFileSync(path.join(root, 'lawspec.edn'), specsManifest);
    return root;
  },
  // A component of specifications for lawspec prove.
  proof: root =>
  {
    mkdirSync(path.join(root, 'laws'));
    for (const name of proofFiles)
    {
      cpSync(
        path.join(repository, 'examples/specs', `${name}.lawspec`),
        path.join(root, 'laws', `${name}.lawspec`),
      );
    }
    writeFileSync(path.join(root, 'lawspec.edn'), specsManifest);
    return root;
  },
  // A component with the four artifact targets, each in its own root.
  artifacts: root =>
  {
    mkdirSync(path.join(root, 'laws'));
    writeFileSync(path.join(root, 'laws/configuration.lawspec'), configuration);
    for (const directory of ['hcl', 'yaml', 'make', 'antlr'])
    {
      mkdirSync(path.join(root, directory));
    }
    writeFileSync(path.join(root, 'lawspec.edn'), artifactManifest);
    return root;
  },
  // A Go program target whose module requires Rapid (lawspec init's go.mod).
  go: root =>
  {
    mkdirSync(path.join(root, 'laws'));
    writeFileSync(path.join(root, 'laws/configuration.lawspec'), configuration);
    writeFileSync(
      path.join(root, 'lawspec.edn'),
      manifest(
        '  :targets [{:language :go :root "."}]\n  :verification {:layers []}',
        'go',
      ),
    );
    writeFileSync(
      path.join(root, 'go.mod'),
      'module example.com/go\n\ngo 1.25.0\n\nrequire pgregory.net/rapid v1.3.0\n',
    );
    writeFileSync(
      path.join(root, 'go.sum'),
      'pgregory.net/rapid v1.3.0 h1:vBvO0VSqti75J1jjYqpgPNBLKMd1+gxa9fYo7vk/Exc=\npgregory.net/rapid v1.3.0/go.mod h1:dPlE4OBBxgXPqkP79flB6sJL1dx5azpI7HQ9MY9Z7uk=\n',
    );
    return root;
  },
  // A Go program target over three of examples/specs: laws that pass, and
  // laws whose generated adapter is still the unimplemented stub, which fail.
  'go-laws': root =>
  {
    fixtures.go(root);
    rmSync(path.join(root, 'laws/configuration.lawspec'));
    for (const name of ['algebra', 'refined_definitions', 'finite_data'])
    {
      cpSync(
        path.join(repository, 'examples/specs', `${name}.lawspec`),
        path.join(root, 'laws', `${name}.lawspec`),
      );
    }
    writeFileSync(
      path.join(root, 'lawspec.edn'),
      manifest(
        '  :targets [{:language :go :root "."}]\n  :verification {:layers [:property]}',
        'go',
      ),
    );
    return root;
  },
  // The attestation specification, with every layer and no targets.
  attested: root =>
  {
    mkdirSync(path.join(root, 'laws'));
    writeFileSync(path.join(root, 'laws/orders.lawspec'), attestedSpec);
    writeFileSync(
      path.join(root, 'lawspec.edn'),
      manifest(`  :targets []\n  ${layers}`, 'shop'),
    );
    return root;
  },
  // A Go program target over examples/specs/refined_definitions, whose
  // laws pass against the generated definitions.
  'go-definitions': root =>
  {
    fixtures.go(root);
    rmSync(path.join(root, 'laws/configuration.lawspec'));
    cpSync(
      path.join(repository, 'examples/specs/refined_definitions.lawspec'),
      path.join(root, 'laws/refined_definitions.lawspec'),
    );
    writeFileSync(
      path.join(root, 'lawspec.edn'),
      manifest(
        '  :targets [{:language :go :root "."}]\n  :verification {:layers [:property]}',
        'go',
      ),
    );
    return root;
  },
  // A JavaScript program target without its package.json.
  javascript: root =>
  {
    mkdirSync(path.join(root, 'laws'));
    writeFileSync(path.join(root, 'laws/configuration.lawspec'), configuration);
    writeFileSync(
      path.join(root, 'lawspec.edn'),
      manifest(
        '  :targets [{:language :javascript :root "."}]\n  :verification {:layers []}',
        'web',
      ),
    );
    return root;
  },
  // examples/packages, run in the component that depends on the others.
  packages: root =>
  {
    cpSync(path.join(repository, 'examples/packages'), root, {
      recursive: true,
    });
    return path.join(root, 'orders');
  },
  'shop-domain': root =>
  {
    cpSync(path.join(repository, 'examples/packages'), root, {
      recursive: true,
    });
    return path.join(root, 'shop-domain');
  },
  'git-packages': root => gitPackages(root),
  // The same, with an executable file and a group-writable one in shop.tax
  // 2.0.0, which git archive records as 0775 and 0664.
  'git-packages-modes': root =>
    gitPackages(root, () =>
      place(path.join(root, 'shop-tax-2'), {
        'tools/run.sh': {content: '#!/bin/sh\necho rates\n', mode: 0o755},
        'tools/notes.txt': {content: 'notes\n', mode: 0o664},
      }),
    ),
  // The same, with the package cache's repository for ../tax.git left
  // without HEAD by an earlier run that did not complete.
  'git-packages-broken': root =>
  {
    const orders = gitPackages(root);
    const digest = createHash('sha256').update('../tax.git').digest('hex');
    place(path.join(root, 'cache/git', digest), {'objects/info/packs': ''});
    return orders;
  },
  // shop.domain publishing a tools folder of assets: an executable, a
  // group-writable file and a private one.
  'shop-domain-modes': root =>
  {
    cpSync(path.join(repository, 'examples/packages'), root, {
      recursive: true,
    });
    const directory = path.join(root, 'shop-domain');
    place(directory, {
      'lawspec.edn':
        '{\n  :manifest-version 1\n  :package {:name "shop.domain" :version "1.2.0"}\n  :language-profile "1.0-rc.2"\n  :sources ["src"]\n  :assets ["tools"]\n  :dependencies {"shop.tax" "^1.0.0"}\n  :packages ["../shop-tax-1"]\n}\n',
      'tools/run.sh': {content: '#!/bin/sh\necho domain\n', mode: 0o755},
      'tools/group.txt': {content: 'group\n', mode: 0o664},
      'tools/private.txt': {content: 'private\n', mode: 0o600},
    });
    return directory;
  },
  // A program target with native bindings.
  haskell: root =>
  {
    cpSync(path.join(repository, 'examples/native-payments/haskell'), root, {
      recursive: true,
    });
    return root;
  },
  // No lawspec.edn anywhere up to the temporary directory's root.
  empty: root => root,
  // An empty directory with a fixed name, which lawspec init names the
  // component and its project after.
  init: root =>
  {
    mkdirSync(path.join(root, 'app'));
    return path.join(root, 'app');
  },
};
// Each target's payments example, as examples/native-payments has it.
for (const language of readdirSync(
  path.join(repository, 'examples/native-payments'),
))
{
  fixtures[`payments-${language}`] = root =>
  {
    cpSync(path.join(repository, 'examples/native-payments', language), root, {
      recursive: true,
    });
    return root;
  };
}

// examples/packages with shop.tax published from a local bare Git
// repository (tags v1.0.0 and v2.0.0, commits with fixed dates, so both
// runs fetch the same objects), which orders names by a relative URL. The
// preparation runs on the copied examples before they are committed.
function gitPackages(root, prepare = null)
{
  cpSync(path.join(repository, 'examples/packages'), root, {
    recursive: true,
  });
  prepare?.();
  const environment = {
    ...process.env,
    GIT_AUTHOR_NAME: 'LawSpec',
    GIT_AUTHOR_EMAIL: 'lawspec@example.invalid',
    GIT_COMMITTER_NAME: 'LawSpec',
    GIT_COMMITTER_EMAIL: 'lawspec@example.invalid',
    GIT_AUTHOR_DATE: '2000-01-01T00:00:00Z',
    GIT_COMMITTER_DATE: '2000-01-01T00:00:00Z',
    GIT_CONFIG_GLOBAL: '/dev/null',
    GIT_CONFIG_NOSYSTEM: '1',
  };
  const work = path.join(root, 'work');
  const git = (...arguments_) =>
    execFileSync('git', arguments_, {
      cwd: root,
      env: environment,
      stdio: 'ignore',
    });
  git('init', '--quiet', '-b', 'main', work);
  for (const [version, source] of [
    ['1.0.0', 'shop-tax-1'],
    ['2.0.0', 'shop-tax-2'],
  ])
  {
    rmSync(path.join(work, 'src'), {recursive: true, force: true});
    cpSync(path.join(root, source), work, {recursive: true});
    git('-C', work, 'add', '-A');
    git('-C', work, 'commit', '--quiet', '-m', version);
    git('-C', work, 'tag', `v${version}`);
  }
  git('init', '--quiet', '--bare', 'tax.git');
  git('-C', work, 'push', '--quiet', '../tax.git', 'main', '--tags');
  rmSync(work, {recursive: true, force: true});
  writeFileSync(
    path.join(root, 'orders/lawspec.edn'),
    '{\n  :manifest-version 1\n  :component {:name "orders" :version "0.1.0"}\n  :sources ["orders.lawspec"]\n  :dependencies {\n    "shop.domain" "^1.0.0"\n    "shop.tax" {:version "^2.0.0" :git "../tax.git"}\n  }\n  :packages ["../shop-domain" "../shop-tax-1"]\n  :targets []\n  :language-profile "1.0-rc.2"\n  :verification {:layers []}\n}\n',
  );
  return path.join(root, 'orders');
}

// The core's usage error for an unknown option or a missing value. The
// legacy CLI threw a Node stack trace there instead (CHANGELOG, 0.34.0), so
// the case states what every CLI prints, the reference included.
const checkUsage =
  'Usage: lawspec check [--warn-matches] [--no-advice] | doctor | explain [<unit>::<law>] [--view eng|math|dev] | generate\n';
const usageError = (problem, usage) => ({
  problem,
  step: {
    stdout: '',
    stderr: `lawspec: ${problem}\n${usage}`,
    exit: 1,
    signal: null,
  },
});
const usageDiagnostic = problem => ({
  problem,
  step: {
    stdout: `${JSON.stringify({diagnostics: [{code: 'usage', message: problem, at: null}]}, null, 2)}\n`,
    stderr: '',
    exit: 1,
    signal: null,
  },
});

// [name, fixture, invocations, {files, expect, normalise, normaliseFile,
// modes, requires, slow}]. Files are written into
// the working directory before the first invocation; null removes one. An
// invocation is its argv, or {argv, env, files, input, serve}, whose files
// are written just before it runs; serve lists the HTTP requests a server
// answers before it is stopped (serveSession). An argument <busy> is a
// port another listener holds. An expect list states what every CLI,
// the reference included, prints for each invocation.
// The servers' transcripts. A Language Server Protocol message with its
// Content-Length header, and a Model Context Protocol line, which for a
// request waits for the reply naming its id (ids 1 to 9, so no id's text
// is a prefix of another's).
const framed = message =>
{
  const body = Buffer.from(JSON.stringify(message));
  return Buffer.concat([
    Buffer.from(`Content-Length: ${body.length}\r\n\r\n`),
    body,
  ]);
};
const mcpLine = message => ({
  data: JSON.stringify(message) + '\n',
  ...(message.id === undefined
    ? {}
    : {until: `"jsonrpc":"2.0","id":${JSON.stringify(message.id)}`}),
});
const mcpOpening = (id = 1) => [
  {
    jsonrpc: '2.0',
    id,
    method: 'initialize',
    params: {
      protocolVersion: '2025-06-18',
      capabilities: {},
      clientInfo: {name: 'host-parity', version: '1'},
    },
  },
  {jsonrpc: '2.0', method: 'notifications/initialized'},
];
const mcpCall = (id, name, args) => ({
  jsonrpc: '2.0',
  id,
  method: 'tools/call',
  params: {name, arguments: args},
});
// An editor's session over laws/algebra.lawspec: open, the queries, an
// edit the formatter rewrites, an edit with an error, close, shutdown and
// exit, written at once, as lsp.mjs handled messages in order.
const lspSession = ({cwd}) =>
{
  const uri = `file://${cwd}/laws/algebra.lawspec`;
  const text = readFileSync(path.join(cwd, 'laws/algebra.lawspec'), 'utf8');
  const at = (id, method, line, character, extra = {}) => ({
    jsonrpc: '2.0',
    id,
    method,
    params: {textDocument: {uri}, position: {line, character}, ...extra},
  });
  const messages = [
    {
      jsonrpc: '2.0',
      id: 1,
      method: 'initialize',
      params: {processId: null, rootUri: `file://${cwd}`, capabilities: {}},
    },
    {jsonrpc: '2.0', method: 'initialized', params: {}},
    {
      jsonrpc: '2.0',
      method: 'textDocument/didOpen',
      params: {textDocument: {uri, languageId: 'lawspec', version: 1, text}},
    },
    at(2, 'textDocument/hover', 19, 12),
    at(3, 'textDocument/hover', 0, 0),
    at(4, 'textDocument/definition', 19, 12),
    at(5, 'textDocument/references', 19, 12, {
      context: {includeDeclaration: true},
    }),
    at(12, 'textDocument/hover', 11, 1),
    at(13, 'textDocument/references', 3, 1),
    {
      jsonrpc: '2.0',
      id: 6,
      method: 'textDocument/documentSymbol',
      params: {textDocument: {uri}},
    },
    {
      jsonrpc: '2.0',
      method: 'textDocument/didChange',
      params: {
        textDocument: {uri, version: 2},
        contentChanges: [{text: text.replace('add           ::', 'add ::')}],
      },
    },
    {
      jsonrpc: '2.0',
      id: 7,
      method: 'textDocument/formatting',
      params: {textDocument: {uri}, options: {tabSize: 2, insertSpaces: true}},
    },
    {
      jsonrpc: '2.0',
      method: 'textDocument/didChange',
      params: {
        textDocument: {uri, version: 3},
        contentChanges: [{text: text.replace('-> Integer\n', '-> Intger\n')}],
      },
    },
    {jsonrpc: '2.0', id: 8, method: 'workspace/symbol', params: {query: ''}},
    {
      jsonrpc: '2.0',
      method: 'textDocument/didChange',
      params: {
        textDocument: {uri, version: 4},
        contentChanges: [{range: {}, text: ''}],
      },
    },
    {jsonrpc: '2.0', id: 9, method: 'textDocument/didChange', params: {}},
    {
      jsonrpc: '2.0',
      method: 'textDocument/didClose',
      params: {textDocument: {uri}},
    },
    {jsonrpc: '2.0', id: 10, method: 'shutdown'},
    at(11, 'textDocument/hover', 3, 1),
    {jsonrpc: '2.0', method: 'exit'},
  ];
  return [{data: Buffer.concat(messages.map(framed))}];
};

// lawspec learn's transcript: requests over loopback, one at a time, to
// the port its ready line names. A response is its status, its headers but
// those of the host's HTTP framing (each host frames a response its own
// way: chunked or Content-Length, Date, keep-alive, Warp's Server), in
// order and as named, and its body's length and SHA-256.
const learnRequests = [
  ['GET', '/'],
  ['HEAD', '/'],
  ['GET', '/index.html?x=1'],
  ['GET', '/style.css'],
  ['GET', '/app.mjs'],
  ['GET', '/curriculum.json'],
  ['GET', '/vendor/manifest.json'],
  ['GET', '/vendor/fonts/atkinson-hyperlegible-latin-400-normal.woff2'],
  ['GET', '/vendor/esbuild.wasm'],
  ['GET', '/vendor/esbuild-wasm-LICENSE.txt'],
  ['GET', '/sandbox-frame.html'],
  ['GET', '/core_jsffi.js'],
  ['GET', '/core.wasm.gz'],
  ['HEAD', '/core.wasm.gz'],
  ['GET', '/core.wasm'],
  ['GET', '/x%2F..%2Findex.html'],
  ['GET', '/a\\..\\index.html'],
  ['GET', '/%2e%2e%2fpackage.json'],
  ['GET', '/../package.json'],
  ['GET', '/..%2Fpackage.json'],
  ['GET', '/vendor'],
  ['GET', '/vendor/'],
  ['GET', '/missing'],
  ['GET', '/%zz'],
  ['GET', '/a%00b'],
  ['GET', '/caf\u00e9'],
  ['GET', 'http://example.test/index.html'],
  ['POST', '/', 'source'],
  ['PUT', '/index.html', ''],
  ['DELETE', '/'],
];
const framing = new Set([
  'date',
  'connection',
  'keep-alive',
  'transfer-encoding',
  'content-length',
  'server',
]);
function exchange(port, [method, target, body])
{
  return new Promise(resolve =>
  {
    const request = http.request(
      {host: '127.0.0.1', port, method, path: target, agent: false},
      response =>
      {
        const chunks = [];
        response.on('data', chunk => chunks.push(chunk));
        response.on('end', () =>
        {
          const bytes = Buffer.concat(chunks);
          const headers = [];
          for (let i = 0; i < response.rawHeaders.length; i += 2)
          {
            if (!framing.has(response.rawHeaders[i].toLowerCase()))
            {
              headers.push([
                response.rawHeaders[i],
                response.rawHeaders[i + 1],
              ]);
            }
          }
          // A gzip body is compared by what it holds: the compressed bytes
          // depend on the zlib build that wrote them.
          const gzip =
            response.headers['content-type'] === 'application/gzip' &&
            bytes.length > 0;
          const content = gzip ? gunzipSync(bytes) : bytes;
          resolve({
            request: `${method} ${target}`,
            status: response.statusCode,
            headers,
            length: content.length,
            sha256: createHash('sha256').update(content).digest('hex'),
          });
        });
      },
    );
    request.on('error', error =>
      resolve({request: `${method} ${target}`, error: error.code}),
    );
    request.end(body);
  });
}
// A server stops on SIGINT; one still running
// after this bound is killed and reported.
const stopMilliseconds = 20000;
// Start a server, wait for its ready line, run the requests and stop it.
// What it printed has its port replaced, since each run listens on its own.
function serveSession(program, args, options, requests)
{
  return new Promise((resolve, reject) =>
  {
    const child = spawn(program, args, {
      ...options,
      stdio: ['ignore', 'pipe', 'pipe'],
    });
    const stdout = [];
    const stderr = [];
    let started = false;
    let killed = false;
    const ready = /Learn LawSpec: http:\/\/127\.0\.0\.1:(\d+)\//;
    const begin = async port =>
    {
      started = true;
      clearTimeout(waiting);
      const responses = [];
      for (const request of requests)
      {
        responses.push(await exchange(port, request));
      }
      child.kill('SIGINT');
      const stopping = setTimeout(() =>
      {
        killed = true;
        child.kill('SIGKILL');
      }, stopMilliseconds);
      child.once('close', () => clearTimeout(stopping));
      return responses;
    };
    let responses = Promise.resolve([]);
    child.stdout.on('data', chunk =>
    {
      stdout.push(chunk);
      const match = ready.exec(Buffer.concat(stdout).toString());
      if (match && !started)
      {
        responses = begin(Number(match[1]));
      }
    });
    child.stderr.on('data', chunk => stderr.push(chunk));
    child.on('error', reject);
    // A server that never says it is ready is stopped after the bound.
    const waiting = setTimeout(() =>
    {
      killed = true;
      child.kill('SIGKILL');
    }, inputWaitMilliseconds);
    child.on('close', async (status, signal) =>
    {
      clearTimeout(waiting);
      const text = Buffer.concat(stdout).toString();
      const port = ready.exec(text)?.[1];
      resolve({
        stdout: Buffer.from(
          port === undefined
            ? text
            : text.replaceAll(`127.0.0.1:${port}/`, '127.0.0.1:<port>/'),
        ),
        stderr: Buffer.concat(stderr),
        status,
        signal: killed ? 'killed after the bound' : signal,
        responses: await responses,
      });
    });
  });
}
// A port another listener holds, for lawspec learn to find in use.
const busy = net.createServer();
await new Promise(resolve => busy.listen(0, '127.0.0.1', resolve));
busy.unref();
const busyPort = String(busy.address().port);

const cases = [
  [
    'usage-errors',
    'specs',
    [
      ['check', '--frob'],
      ['explain', '--tag'],
      ['test', '--seed'],
      ['fmt', '.', '--json', '--bogus'],
      ['--version', '--x'],
    ],
    {
      expect: [
        usageError('Unknown option: --frob', checkUsage),
        usageError('Missing value for --tag', checkUsage),
        usageError(
          'Missing value for --seed',
          'Usage: lawspec test [--target <language>] [--fresh] [--seed <n>] [--attestation <file>] [--update-recorded] [--tag <t>] [--exclude-tag <t>] [--report junit=<path>] [--coverage] [--benchmarks]\n',
        ),
        usageDiagnostic('Unknown option: --bogus'),
        usageError(
          'Unknown option: --x',
          'Run lawspec help for the commands and their options.\n',
        ),
      ],
    },
  ],
  ['fmt-check', 'flat', [['fmt', '--check', '.']]],
  ['fmt-check-json', 'flat', [['fmt', '--check', '--json', '.']]],
  [
    'fmt-write-then-check',
    'flat',
    [
      ['fmt', '.'],
      ['fmt', '--check', '.'],
    ],
  ],
  [
    'fmt-write-json-files',
    'flat',
    [['fmt', '--json', 'boolean_flags.lawspec', 'actors.lawspec']],
  ],
  [
    'fmt-compile',
    'flat',
    [['fmt', '--check', '--compile', 'boolean_flags.lawspec']],
  ],
  ['fmt-missing-path', 'flat', [['fmt', 'missing.lawspec']]],
  ['fmt-no-sources', 'flat', [['fmt', '--check', 'README.txt']]],
  ['fmt-bad-option', 'flat', [['fmt', '.', '--strict']]],
  ['fmt-bad-option-json', 'flat', [['fmt', '.', '--json', '--minify']]],
  [
    'fmt-machine-bits',
    'flat',
    [['fmt', '--check', '--machine-bits', '33', '.']],
  ],
  [
    'fmt-diagnostics',
    'flat',
    [['fmt', 'broken.lawspec']],
    {files: {'broken.lawspec': broken}},
  ],
  [
    'fmt-diagnostics-json',
    'flat',
    [['fmt', '--json', '--compile', '.']],
    {files: {'broken.lawspec': broken}},
  ],
  // A parse error whose span ends at a newline, then one over a control
  // character, in a directory with no packages: megaparsec underlines only
  // the visible characters, so the native build must resolve the version
  // the WebAssembly core pins.
  [
    'fmt-parse-error-carets',
    'empty',
    [
      ['fmt', 'newline.lawspec'],
      ['fmt', 'control.lawspec'],
    ],
    {
      files: {
        'newline.lawspec':
          'unit demo\nlaw broken:\n  forall x.\nend law\nend unit\n',
        'control.lawspec': 'x\u0001\n',
      },
    },
  ],
  [
    'fmt-bits-32-compile',
    'flat',
    [['fmt', '--compile', '--machine-bits', '0x20', 'atoi_codec.lawspec']],
  ],
  // Usage and option errors, in the order main() checks them.
  ['usage', 'empty', [[]]],
  ['usage-help', 'empty', [['help'], ['--help'], ['-h', '--json']]],
  ['version', 'empty', [['--version']]],
  ['bad-machine-bits', 'empty', [['check', '--machine-bits', 'x']]],
  [
    'prelude-usage',
    'empty',
    [
      ['prelude', 'a', 'b'],
      ['prelude', '--target', 'go'],
    ],
  ],
  [
    'strict',
    'specs',
    [
      ['check', '--strict'],
      ['check', '--strict', '--json'],
    ],
  ],
  ['no-advice', 'specs', [['explain', '--no-advice']]],
  [
    'learn-usage',
    'empty',
    [
      ['learn', 'x'],
      ['learn', '--json'],
    ],
  ],
  // lawspec learn serving the site, the compiler and its glue, and refusing
  // the rest, then stopped with SIGINT. Serving the gzipped compiler takes
  // seconds.
  [
    'learn-serve',
    'empty',
    [{argv: ['learn', '--port', '0'], serve: learnRequests}],
    {slow: 30},
  ],
  [
    'learn-port',
    'empty',
    [
      ['learn', '--port', 'x'],
      ['learn', '--port', '65536'],
      ['learn', '--port', '<busy>'],
      ['learn', '--port', '<busy>', '--json'],
    ],
  ],
  ['port', 'specs', [['check', '--port', '1']]],
  [
    'project-usage',
    'specs',
    [
      ['project'],
      ['project', 'bogus'],
      ['project', 'status', '--config', 'lawspec.edn', '--project', '.'],
      ['project', 'status', '--languages', 'go'],
    ],
  ],
  ['languages', 'specs', [['check', '--languages', 'go']]],
  ['compile-option', 'specs', [['check', '--compile']]],
  [
    'unexpected-argument',
    'specs',
    [
      ['check', 'a', 'b'],
      ['explain', 'a', 'b'],
    ],
  ],
  [
    'examples-usage',
    'empty',
    [
      ['examples', '--check'],
      ['examples', '--target', 'hcl'],
      ['examples', '--target', 'cobol'],
      ['examples', '--example', 'shop'],
    ],
  ],
  [
    'option-scope',
    'specs',
    [
      ['check', '--solver', 'z3'],
      ['check', '--view', 'math'],
      ['check', '--output', 'x'],
      ['check', '--example', 'payments'],
      ['check', '--no-install'],
      ['check', '--name', 'x'],
      ['init', '--target', 'go', '--release', '21'],
      ['check', '--minify'],
      ['check', '--fresh'],
      ['check', '--tag', 'a,b'],
      ['check', '--attestation', 'a.json'],
      ['test', '--seed', '1x'],
      ['explain', '--warn-matches'],
      ['check', '--stdio'],
      ['lsp'],
      ['mcp', '--target', 'go'],
      ['bogus'],
    ],
  ],
  ['no-manifest', 'empty', [['check'], ['check', '--json'], ['explain']]],
  ['json-manifest', 'empty', [['check']], {files: {'lawspec.json': '{}\n'}}],
  [
    'invalid-manifest',
    'specs',
    [['check'], ['check', '--json']],
    {files: {'lawspec.edn': '{:manifest-version 1'}},
  ],
  [
    'unknown-manifest-field',
    'specs',
    [['check'], ['check', '--json']],
    {files: {'lawspec.edn': manifest('  :targets []\n  :bogus 1')}},
  ],
  [
    'config-missing',
    'specs',
    [
      ['check', '--config', 'other.edn'],
      ['check', '--config', 'other.json'],
    ],
  ],
  [
    'config-other',
    'specs',
    [['check', '--config', 'sub/other.edn']],
    {
      files: {
        'sub/other.edn': manifest('  :targets []').replace(
          '"laws"',
          '"../laws"',
        ),
      },
    },
  ],
  // The compile commands over the component without targets.
  ['check', 'specs', [['check']]],
  ['check-json', 'specs', [['check', '--json']]],
  ['check-no-advice', 'specs', [['check', '--no-advice']]],
  ['check-warn-matches', 'specs', [['check', '--warn-matches', '--json']]],
  ['check-twice', 'specs', [['check'], ['check', '--json']]],
  ['check-no-cache', 'specs', [['check', '--no-cache']]],
  [
    'check-cache-false',
    'specs',
    [['check']],
    {
      files: {
        'lawspec.edn': manifest(`  :targets []\n  :cache false\n  ${layers}`),
      },
    },
  ],
  [
    'check-cache-directory',
    'specs',
    [['check']],
    {
      files: {
        'lawspec.edn': manifest(
          `  :targets []\n  :cache-directory "shared-cache"\n  ${layers}`,
        ),
      },
    },
  ],
  [
    'check-cache-variable',
    'specs',
    [{argv: ['check'], env: {LAWSPEC_COMPILER_CACHE: 'variable-cache'}}],
  ],
  [
    'check-stale-cache',
    'specs',
    [['check']],
    {
      files: {
        '.lawspec/cache/0123456789abcdef/x': 'old\n',
        '.lawspec/cache/stale/x': 'old\n',
        '.lawspec/cache/solver-goals-v1/y': 'old\n',
      },
    },
  ],
  [
    'check-bad-cache-settings',
    'specs',
    [
      {
        argv: ['check'],
        files: {'lawspec.edn': manifest('  :targets []\n  :cache 1')},
      },
      {
        argv: ['check'],
        files: {
          'lawspec.edn': manifest('  :targets []\n  :cache-directory ""'),
        },
      },
      {
        argv: ['check'],
        files: {'lawspec.edn': manifest('  :targets []\n  :machine-bits 16')},
      },
    ],
  ],
  // A failing run removes the .lawspec folder it created.
  [
    'check-diagnostics',
    'specs',
    [['check'], ['check', '--json']],
    {files: {'laws/broken.lawspec': broken}},
  ],
  [
    'check-machine-bits',
    'specs',
    [['check', '--machine-bits', '32', '--json']],
  ],
  ['explain', 'specs', [['explain']]],
  ['explain-json', 'specs', [['explain', '--json']]],
  [
    'explain-law',
    'specs',
    [
      ['explain', 'example.atoi_codec::roundTrip'],
      ['explain', 'example.atoi_codec::roundTrip', '--view', 'math'],
    ],
  ],
  [
    'explain-views',
    'specs',
    [
      ['explain', '--view', 'dev'],
      ['explain', '--view', 'bogus'],
    ],
  ],
  ['explain-unknown-law', 'specs', [['explain', 'no.such::law']]],
  // lawspec evidence: every obligation by status, one unit's or one
  // declaration's, none matching, and an attestation that is not there.
  [
    'evidence',
    'specs',
    [
      ['evidence'],
      ['evidence', '--json'],
      ['evidence', 'example.atoi_codec'],
      ['evidence', 'example.atoi_codec::roundTrip', '--json'],
      ['evidence', 'no.such::law'],
      ['evidence', '--attestation', 'missing.json'],
      ['evidence', '--json', '--no-cache'],
    ],
  ],
  // A refuted law fails evidence, which still lists it.
  [
    'evidence-refuted',
    'specs',
    [['evidence'], ['evidence', '--json']],
    {files: {'laws/refuted.lawspec': refutedLaw}},
  ],
  [
    'evidence-diagnostics',
    'specs',
    [['evidence'], ['evidence', '--json']],
    {files: {'laws/broken.lawspec': broken}},
  ],
  [
    'evidence-no-layers',
    'specs',
    [['evidence']],
    {
      files: {
        'lawspec.edn': manifest('  :targets []\n  :verification {:layers []}'),
      },
    },
  ],
  // Where tests ran: a named attestation, one lawspec.edn names, a version
  // the compiler rejects, and runs lawspec test recorded.
  [
    'evidence-attestation',
    'attested',
    [
      ['evidence'],
      ['evidence', '--json', '--attestation', 'staging.json'],
      ['evidence', '--attestation', 'staging.json'],
      {
        argv: ['evidence', '--json'],
        files: {
          'lawspec.edn': manifest(
            `  :targets []\n  :attestation "staging.json"\n  ${layers}`,
            'shop',
          ),
        },
      },
      {
        argv: ['evidence'],
        files: {
          'staging.json': JSON.stringify({
            ...attestationDocument('run-3'),
            version: 2,
          }),
        },
      },
      ['explain'],
    ],
    {files: {'staging.json': JSON.stringify(attestationDocument('run-2'))}},
  ],
  [
    'evidence-attested-runs',
    'attested',
    [
      ['evidence'],
      ['evidence', '--json'],
      ['evidence', 'shop.orders::checkoutCharges'],
    ],
    {
      files: attestedResults({
        laws: {
          'shop.orders::law::checkoutCharges': passedIn('run-4'),
          'shop.orders::law::normalizing': passedIn(),
        },
        attestations: {'run-4': attestationDocument('run-4')},
      }),
    },
  ],
  // A completed run's document links the laws of its run; wiring, a run
  // under way and another run stay planned. Then the run lawspec test stored
  // in each state, unnamed.
  [
    'evidence-completed-run',
    'attested',
    [
      ['evidence', '--attestation', 'run.json'],
      ['evidence', '--json', '--attestation', 'run.json'],
      ...[
        {status: 'wired'},
        {status: 'running'},
        {status: 'completed', exit_code: 0},
      ].map((execution, index) => ({
        argv: ['evidence', '--attestation', 'run.json'],
        files: {
          'run.json': JSON.stringify(
            executedDocument(index === 2 ? 'run-6' : 'run-5', execution),
          ),
        },
      })),
      ...['running', 'wired', 'completed'].flatMap(status => [
        {
          argv: ['evidence'],
          files: attestedResults({
            laws: {'shop.orders::law::checkoutCharges': passedIn('run-5')},
            attestations: {
              'run-5': executedDocument('run-5', {
                status,
                ...(status === 'completed' ? {exit_code: 0} : {}),
              }),
            },
          }),
        },
        ['evidence', '--json'],
      ]),
    ],
    {
      files: {
        ...attestedResults({
          laws: {'shop.orders::law::checkoutCharges': passedIn('run-5')},
          attempts: {
            'shop.orders::law::normalizing': {
              key: 'k',
              seed: 1,
              at: '2026-10-09T19:31:00.000Z',
              outcome: 'failed',
              environment: 'run-5',
            },
          },
          attestations: {'run-5': attestationDocument('run-5')},
        }),
        'run.json': JSON.stringify(
          executedDocument('run-5', {
            status: 'completed',
            exit_code: 1,
            finished_at: '2026-10-09T19:32:00Z',
          }),
        ),
      },
    },
  ],
  [
    'inspect-without-target',
    'specs',
    [['inspect'], ['inspect', '--target', 'go']],
  ],
  [
    'generate-without-targets',
    'specs',
    [['generate'], ['doctor', '--target', 'go']],
  ],
  ['describe', 'specs', [['describe'], ['describe', '--json']]],
  [
    'prelude',
    'empty',
    [['prelude'], ['prelude', 'length'], ['prelude', 'Text', '--json']],
  ],
  [
    'fmt-manifest',
    'specs',
    [
      ['fmt', '--check'],
      ['fmt', '--json'],
      ['fmt', '--check'],
    ],
  ],
  [
    'test-without-native-layers',
    'specs',
    [
      {
        argv: ['test'],
        files: {
          'lawspec.edn': manifest(
            '  :targets []\n  :verification {:layers [:proof :runtime]}',
          ),
        },
      },
      {
        argv: ['test', '--json'],
        files: {
          'lawspec.edn': manifest(
            '  :targets []\n  :verification {:layers []}',
          ),
        },
      },
    ],
  ],
  // Artifact targets: generation, ownership and the advice for them.
  ['artifacts-generate', 'artifacts', [['generate']]],
  ['artifacts-generate-json', 'artifacts', [['generate', '--json']]],
  [
    'artifacts-dry-run',
    'artifacts',
    [
      ['generate', '--dry-run'],
      ['generate', '--check'],
    ],
  ],
  [
    'artifacts-regenerate',
    'artifacts',
    [['generate'], ['generate', '--check'], ['generate']],
  ],
  [
    'artifacts-minify',
    'artifacts',
    [
      ['generate', '--minify'],
      ['generate', '--check'],
    ],
  ],
  [
    'artifacts-target',
    'artifacts',
    [
      ['generate', '--target', 'yaml'],
      ['generate', '--target', 'go'],
    ],
  ],
  ['artifacts-exclusive', 'artifacts', [['generate', '--dry-run', '--check']]],
  [
    'artifacts-edited',
    'artifacts',
    [
      ['generate'],
      {argv: ['generate'], files: {'yaml/configuration.yaml': 'edited\n'}},
      {argv: ['generate', '--json'], files: {'yaml/configuration.yaml': null}},
    ],
  ],
  [
    'artifacts-unowned',
    'artifacts',
    [['generate']],
    {files: {'make/Makefile': 'all:\n'}},
  ],
  [
    'artifacts-missing-root',
    'artifacts',
    [['generate']],
    {
      files: {
        'lawspec.edn': manifest(
          '  :targets [{:language :make :root "missing"}]',
          'artifacts',
        ),
      },
    },
  ],
  [
    'artifacts-shared-root',
    'artifacts',
    [['generate']],
    {
      files: {
        'lawspec.edn': manifest(
          '  :targets [{:language :make :root "make"} {:language :yaml :root "make/."}]',
          'artifacts',
        ),
      },
    },
  ],
  ['artifacts-check', 'artifacts', [['check'], ['check', '--json']]],
  [
    'artifacts-inspect',
    'artifacts',
    [
      ['inspect', '--target', 'yaml'],
      ['inspect', '--target', 'hcl', '--json'],
    ],
  ],
  ['artifacts-explain', 'artifacts', [['explain']]],
  ['artifacts-describe', 'artifacts', [['describe']]],
  // Local contract packages: resolution and the lockfile.
  ['packages-check', 'packages', [['check']]],
  ['packages-check-json', 'packages', [['check', '--json']]],
  [
    'packages-locked',
    'packages',
    [['check', '--locked'], ['check'], ['check', '--locked']],
  ],
  ['packages-describe', 'packages', [['describe']]],
  ['packages-explain', 'packages', [['explain']]],
  ['packages-fmt', 'packages', [['fmt', '--check']]],
  ['package-describe', 'shop-domain', [['describe']]],
  // lawspec fetch and update over local packages, with the package cache
  // in the temporary root.
  [
    'packages-fetch',
    'packages',
    [
      ['fetch'],
      ['fetch', '--json'],
      ['update'],
      ['update', 'shop.tax', '--json'],
      ['fetch', '--locked'],
      ['update', 'a', 'b'],
    ].map(argv => ({argv, env: {LAWSPEC_CACHE_DIR: '../cache'}})),
  ],
  // Git packages: ls-remote, fetch and archive through spawn, the tar the
  // core unpacks into the cache, the lock, and offline reuse.
  [
    'packages-git',
    'git-packages',
    [
      ['fetch'],
      ['fetch', '--offline', '--json'],
      ['check', '--locked'],
      ['update', 'shop.tax'],
      ['describe'],
      ['check', '--offline'],
    ].map(argv => ({argv, env: {LAWSPEC_CACHE_DIR: '../cache'}})),
    {requires: ['git'], modes: true},
  ],
  // An archive with an executable unpacks with the modes node-tar's
  // extract gives it, into a cache entry renamed into place.
  [
    'packages-git-modes',
    'git-packages-modes',
    [['fetch'], ['check', '--locked']].map(argv => ({
      argv,
      env: {LAWSPEC_CACHE_DIR: '../cache'},
    })),
    {requires: ['git'], modes: true},
  ],
  // A cached repository without HEAD stays as it is and is reported.
  [
    'packages-git-broken',
    'git-packages-broken',
    [['fetch']].map(argv => ({argv, env: {LAWSPEC_CACHE_DIR: '../cache'}})),
    {requires: ['git'], modes: true},
  ],
  [
    'packages-git-offline',
    'git-packages',
    [['fetch', '--offline'], ['check']].map(argv => ({
      argv,
      env: {LAWSPEC_CACHE_DIR: '../cache', LAWSPEC_OFFLINE: '1'},
    })),
    {requires: ['git']},
  ],
  // lawspec package: the summary, the portable archive, a package named by
  // --project, and a component without a package identity.
  [
    'package',
    'shop-domain',
    [
      ['package'],
      ['package', '--json', '--output', '../out/shop-domain.tgz'],
      ['package', '--project', '../shop-tax-2', '--output', 'dist/tax.tgz'],
      ['package', '--config', '../orders/lawspec.edn'],
    ],
    {modes: true},
  ],
  // The archive records each file's mode as node-tar's portable mode does:
  // 0755, 0644 for the group-writable file, and 0600.
  [
    'package-modes',
    'shop-domain-modes',
    [['package', '--json', '--output', '../out/shop-domain.tgz']],
    {modes: true},
  ],
  // lawspec init: new and existing projects, artifact and program targets,
  // JSON build files it updates or refuses, and a missing build tool.
  [
    'init-new',
    'init',
    [
      ['init', '--target', 'yaml', '--no-install'],
      ['init', '--target', 'hcl', '--project', 'infra', '--no-install'],
      ['init', '--target', 'make'],
      ['init', '--target', 'bogus'],
      ['init', '--target', 'javascript', '--project', 'web', '--no-install'],
      [
        'init',
        '--target',
        'typescript',
        '--project',
        'web2',
        '--no-install',
        '--minify',
      ],
      [
        'init',
        '--target',
        'java',
        '--project',
        'jv',
        '--release',
        '21',
        '--generated-source-dir',
        'gen/main',
        '--generated-test-dir',
        'gen/test',
        '--no-install',
      ],
      [
        'init',
        '--target',
        'java',
        '--project',
        'jv',
        '--release',
        '25',
        '--no-install',
      ],
      [
        'init',
        '--target',
        'python',
        '--project',
        'py',
        '--no-install',
        '--machine-bits',
        '32',
      ],
      ['init', '--target', 'yaml', '--no-install'],
      [
        'init',
        '--target',
        'go',
        '--project',
        'gomod',
        '--name',
        'example.com/demo',
        '--no-install',
      ],
      [
        'init',
        '--target',
        'rust',
        '--project',
        'rs',
        '--no-install',
        '--name',
        'demo-crate',
      ],
      ['init', '--target', 'haskell', '--project', 'hs', '--no-install'],
      ['init', '--target', 'csharp', '--project', 'cs', '--no-install'],
      [
        'init',
        '--target',
        'yaml',
        '--config',
        'sub/lawspec.edn',
        '--no-install',
      ],
    ],
  ],
  [
    'init-existing',
    'init',
    [
      ['init', '--target', 'yaml', '--no-install'],
      ['init', '--target', 'yaml', '--project', 'b', '--no-install'],
      ['init', '--target', 'javascript', '--project', 'web', '--no-install'],
      ['init', '--target', 'typescript', '--project', 'tsx', '--no-install'],
      {
        argv: [
          'init',
          '--target',
          'javascript',
          '--project',
          'cjs',
          '--no-install',
        ],
        files: {
          'cjs/package.json': '{"name":"cjs","type":"commonjs"}',
          'cjs/lib/index.js': 'module.exports = 1;\n',
        },
      },
    ],
    {
      files: {
        'lawspec.edn':
          '{:manifest-version 1 :component {:name "s" :version "0.1.0"} :language-profile "1.0-rc.2" :sources ["laws"] :targets [{:language :yaml :root "a"} {:language :yaml :root "b"}]}\n',
        'web/package.json':
          '{\n    "name": "web",\n    "type": "commonjs",\n    "dependencies": {"fast-check": "^3"}\n}\n',
        'tsx/package.json': '{\n\t"name": "tsx"\n}\n',
      },
    },
  ],
  [
    'init-json-manifest',
    'empty',
    [['init', '--target', 'yaml']],
    {files: {'lawspec.json': '{}\n'}},
  ],
  [
    'init-missing-tool',
    'init',
    [
      ['init', '--target', 'go', '--project', 'go'],
      ['init', '--target', 'python', '--project', 'py'],
    ].map(argv => ({argv, env: {PATH: '/nonexistent'}})),
  ],
  // lawspec project: adopting a project Canon is already set up in, the
  // checks made before anything is written, and status and validate with
  // Canon absent, a canon executable named by CANON, and no manifest.
  [
    'project-adopt',
    'init',
    [
      ['project', 'adopt'],
      ['project', 'adopt', '--json'],
      ['project', 'init'],
      ['project', 'adopt', '--project', 'sub', '--languages', 'go'],
      ['project', 'adopt', '--config', 'bad/lawspec.edn'],
      ['project', 'init', '--project', 'old'],
      ['project', 'init', '--project', 'half', '--json'],
      ['project', 'init', '--project', 'manifest'],
    ],
    {
      files: {
        'canon.yaml': '{\n  "version": "0.1.0"\n}\n',
        'sub/canon.yaml': 'canon: 0.2\n',
        'sub/laws/a.lawspec': 'unit a\nend unit\n',
        'bad/canon.yaml': '{}\n',
        'bad/lawspec.edn': '{:manifest-version 2}\n',
        'old/lawspec-package.json': '{}\n',
        'half/.ricestax/languages.json': '{}\n',
        'manifest/lawspec.edn': '{}\n',
      },
    },
  ],
  // Canon's setup: ricestax@0.4.3's presets, from the Canon each host
  // ships, copied into .ricestax/ beside canon.yaml and the empty ledgers;
  // the languages chosen, repeated or unknown; then Canon's own checks of
  // the project it set up.
  [
    'project-init-canon',
    'init',
    [
      ['project', 'init'],
      [
        'project',
        'adopt',
        '--project',
        'b',
        '--languages',
        'go,java',
        '--json',
      ],
      ['project', 'init', '--project', 'c', '--languages', 'folio,calm,folio'],
      ['project', 'init', '--project', 'd', '--languages', 'go,cobol'],
      ['project', 'init', '--project', 'e', '--languages', 'go,'],
      {
        argv: ['project', 'status'],
        files: {'docs/a.md': '# A\n\nSome text.\n'},
      },
      ['project', 'validate', '--json'],
    ],
    {modes: true},
  ],
  [
    'project-status',
    'specs',
    [
      ['project', 'status'],
      ['project', 'status', '--json'],
      ['project', 'validate'],
      ['project', 'validate', '--json'],
      ['project', 'status', '--config', 'lawspec.edn'],
      {argv: ['project', 'validate'], files: {'laws/broken.lawspec': broken}},
      {
        argv: ['project', 'status', '--json'],
        files: {
          'laws/broken.lawspec': null,
          'lawspec.edn': manifest(
            '  :targets []\n  :verification {:layers []}',
          ),
        },
      },
      ['project', 'validate', '--json'],
    ],
    {
      files: {
        'lawspec.edn': manifest(
          '  :targets []\n  :verification {:layers [:exhaustive :property]}',
        ),
      },
    },
  ],
  [
    'project-status-empty',
    'empty',
    [
      ['project', 'status'],
      ['project', 'validate', '--json'],
    ],
  ],
  [
    'project-canon',
    'specs',
    [
      ['project', 'status'],
      ['project', 'status', '--json'],
      ['project', 'validate', '--json'],
    ]
      .map(argv => ({argv, env: {CANON: './fake-canon'}}))
      .concat([
        {argv: ['project', 'status', '--json'], env: {CANON: './old-canon'}},
        {argv: ['project', 'status'], env: {CANON: './missing-canon'}},
        {
          argv: ['project', 'validate'],
          env: {CANON: 'fake-canon', PATH: '/nonexistent'},
        },
      ]),
    {
      files: {
        'lawspec.edn': manifest(
          '  :targets []\n  :verification {:layers [:exhaustive]}',
        ),
        'canon.yaml': 'canon: "0.2.x"\nlanguages: {}\n',
        'fake-canon': {
          content:
            '#!/bin/sh\ncase "$1" in\n  version) echo "canon 0.2.3" ;;\n  check) printf \'{"findings": []}\\n\' ;;\n  decisions) echo "2 open decisions"; echo "review needed" >&2; exit 2 ;;\nesac\n',
          mode: 0o755,
        },
        'old-canon': {content: '#!/bin/sh\necho "canon 0.1.9"\n', mode: 0o755},
      },
    },
  ],
  // validate's proof row is lawspec prove's report, whose evidence replaces
  // the check's; definitions that fail skip it. A second proof run would
  // report the receipts the first stored, which are keyed by the host that
  // ran it, so each case proves once.
  [
    'project-validate-proof',
    'proof',
    [
      ['project', 'validate'],
      {
        argv: ['project', 'validate', '--json'],
        files: {'laws/broken.lawspec': broken},
      },
    ],
    {
      requires: ['z3'],
      normalise: withoutTimes,
      files: {
        'lawspec.edn': manifest(
          '  :targets []\n  :verification {:layers [:proof :property]}',
        ),
      },
    },
  ],
  // validate's native row is lawspec test's report: generated files out
  // of date, then laws whose recorded results are unchanged.
  [
    'project-validate-native',
    'go-definitions',
    [
      ['project', 'validate', '--json'],
      ['generate', '--no-advice'],
      ['test', '--seed', '1'],
      ['project', 'validate'],
      ['project', 'validate', '--json'],
    ],
    {
      requires: ['go'],
      normalise: text => withoutRunTimes(withoutSeeds(text)),
      normaliseFile: testResults,
    },
  ],
  // lawspec evidence and explain with the native results lawspec test
  // recorded: matching inputs, then a project file the laws do not read,
  // a generated file that is missing, and one edited, which is refused.
  [
    'evidence-native',
    'go-definitions',
    [
      ['evidence'],
      ['generate', '--no-advice'],
      ['test', '--seed', '1'],
      ['evidence'],
      ['evidence', '--json'],
      ['evidence', 'example.refined_definitions'],
      {argv: ['evidence'], files: {'notes.txt': 'changed\n'}},
      {
        argv: ['evidence', '--json'],
        files: {'example/refined_definitions/lawspec_definitions.go': null},
      },
      {
        argv: ['evidence'],
        files: {
          'example/refined_definitions/lawspec_definitions.go':
            'package refined_definitions\n',
        },
      },
    ],
    {
      requires: ['go'],
      normalise: withoutObservedRuns,
      normaliseFile: testResults,
    },
  ],
  [
    'explain-native',
    'go-definitions',
    [
      ['generate', '--no-advice'],
      ['test', '--seed', '1'],
      ['explain'],
      ['explain', '--json'],
      ['explain', '--view', 'dev'],
      {argv: ['explain'], files: {'notes.txt': 'changed\n'}},
    ],
    {
      requires: ['go'],
      normalise: withoutObservedRuns,
      normaliseFile: testResults,
    },
  ],
  // Laws whose adapter is still the stub fail: their recorded failures.
  [
    'evidence-native-failing',
    'go-laws',
    [
      ['generate', '--no-advice'],
      ['test', '--seed', '1'],
      ['evidence'],
      ['evidence', '--json'],
      ['explain', '--view', 'dev'],
    ],
    {
      requires: ['go'],
      normalise: withoutObservedRuns,
      normaliseFile: testResults,
    },
  ],
  // Without CANON (or with it empty), the Canon the host ships.
  [
    'project-canon-shipped',
    'specs',
    [
      {argv: ['project', 'status'], env: {CANON: ''}},
      ['project', 'validate', '--json'],
    ],
    {files: {'canon.yaml': '{}\n'}},
  ],
  // Without canon.yaml, CANON is not needed; every layer selected, and no
  // application target for the execution layers.
  [
    'project-validate-specs',
    'specs',
    [{argv: ['project', 'validate', '--json'], env: {CANON: ''}}],
    {requires: ['z3'], normalise: withoutTimes},
  ],
  // lawspec examples: the bundled specifications for a program target
  // (compiling all of them takes minutes per runner, so for one target, then
  // again for its JSON), and each target's payments project.
  [
    'examples',
    'empty',
    [
      ['examples', '--target', 'go'],
      ['examples', '--target', 'go', '--json'],
      ['examples', '--output', '../x'],
    ],
    // The longest case by far: started first, so it does not finish alone.
    {slow: 1},
  ],
  [
    'examples-payments',
    'empty',
    [
      ['examples', '--example', 'payments'],
      ['examples', '--example', 'payments', '--json'],
      [
        'examples',
        '--example',
        'payments',
        '--target',
        'gleam',
        '--minify',
        '--machine-bits',
        '32',
        '--output',
        'np',
      ],
    ],
  ],
  [
    'examples-payments-updates',
    'empty',
    [
      ['examples', '--example', 'payments', '--target', 'go'],
      ['examples', '--example', 'payments', '--target', 'rust', '--json'],
    ],
    {
      files: {
        'native_payments/go/.lawspec/example.json':
          '{"version": 1, "files": {}, "adapters": {"go.mod": "0"}}\n',
        'native_payments/go/go.mod': 'module example.com/mine\n',
        'native_payments/rust/src/lib.rs': '// mine\n',
      },
    },
  ],
  // lawspec prove: Z3 through spawn and poll, the semantic receipt cache,
  // counterexamples the evaluator confirms, and the Z3 options.
  ['prove', 'proof', [['prove'], ['prove']], {requires: ['z3']}],
  [
    'prove-json',
    'proof',
    [['prove', '--json', '--solver', '<z3>']],
    {requires: ['z3'], normalise: withoutTimes},
  ],
  [
    'prove-refuted',
    'proof',
    [['prove'], ['prove', '--json', '--solver', '<z3>']],
    {
      requires: ['z3'],
      normalise: withoutTimes,
      files: {
        'laws/wrong.lawspec': wrongLaw,
        'lawspec.edn': manifest(
          '  :targets []\n  :verification {:layers [:proof]}',
        ),
      },
    },
  ],
  [
    'prove-diagnostics',
    'specs',
    [['prove'], ['prove', '--json']],
    {requires: ['z3']},
  ],
  [
    'prove-unavailable',
    'proof',
    [
      ['prove', '--solver', 'missing-z3'],
      ['prove', '--solver', '/nowhere/z3', '--json'],
    ],
    {normalise: withoutTimes},
  ],
  [
    'prove-options',
    'proof',
    [
      ['prove', '--proof-timeout', '0'],
      ['prove', '--proof-memory', 'x'],
      ['prove', '--proof-rlimit', '-1'],
      ['prove', '--proof-seed', '1.5', '--json'],
    ],
  ],
  [
    'prove-without-proof-layer',
    'proof',
    [
      {
        argv: ['prove'],
        files: {
          'lawspec.edn': manifest(
            '  :targets []\n  :verification {:layers [:property]}',
          ),
        },
      },
    ],
  ],
  // A program target: its bindings are checked, its native sources
  // analysed for authoring advice and its toolchain probed.
  ['program-check-no-advice', 'haskell', [['check', '--no-advice']]],
  ['program-check', 'haskell', [['check'], ['check', '--json']]],
  // The doctor fails before generation writes anything (no .cabal file).
  ['program-generate', 'haskell', [['generate', '--no-advice']]],
  ['program-describe', 'haskell', [['describe']]],
  ['program-inspect', 'haskell', [['inspect', '--target', 'haskell']]],
  // lawspec advise: the compiler's own findings, and the analysis of each
  // selected target's native sources against its generation plan.
  [
    'advise',
    'specs',
    [['advise'], ['advise', '--json'], ['advise', '--strict']],
  ],
  [
    'advise-artifacts',
    'artifacts',
    [['advise'], ['advise', '--json', '--strict']],
  ],
  [
    'program-advise',
    'haskell',
    [
      ['advise'],
      ['advise', '--json'],
      ['advise', '--target', 'haskell', '--strict'],
    ],
  ],
  [
    'program-generate-advice',
    'haskell',
    [['generate'], ['generate', '--json']],
  ],
  [
    'advise-javascript',
    'javascript',
    [
      ['advise', '--json'],
      ['advise', '--strict'],
      ['check'],
      ['check', '--json'],
    ],
    {
      files: {
        'clone.mjs': 'export class Settings {}\n',
        'convert.mjs':
          "import {Settings} from './clone.mjs';\nexport function convert(s) { return new Settings(s.port); }\n",
        'other.py': 'class Settings:\n    pass\n',
      },
    },
  ],
  [
    'advise-javascript-excepted',
    'javascript',
    [
      ['advise', '--strict', '--json'],
      ['advise', '--strict'],
    ],
    {
      files: {
        'clone.mjs': 'export class Settings {}\n',
        'lawspec.edn': manifest(
          '  :targets [{:language :javascript :root "."}]\n  :verification {:layers []}\n  :authoring-exceptions [{:declaration "clone.mjs::Settings" :rule "native-model" :reason "Independent reference model"}]',
          'web',
        ),
      },
    },
  ],
  [
    'advise-javascript-unreadable',
    'javascript',
    [['advise'], ['advise', '--json']],
    {
      files: {
        'broken.mjs': 'class {\n',
        'view.tsx': 'const Settings = () => <div/>;\n',
        'foreign.mjs': "import {Settings} from './missing.mjs';\n",
      },
    },
  ],
  [
    'advise-invalid-exceptions',
    'javascript',
    [['advise'], ['check']],
    {
      files: {
        'lawspec.edn': manifest(
          '  :targets [{:language :javascript :root "."}]\n  :verification {:layers []}\n  :authoring-exceptions [{:declaration "x" :rule "native-model" :reason " "}]',
          'web',
        ),
      },
    },
  ],
  [
    'advise-go',
    'go',
    [['advise'], ['generate', '--json'], ['advise', '--json']],
    {
      files: {
        'model.go':
          'package model\n\nimport "fmt"\n\ntype Settings struct {\n\tPort    uint16\n\tEnabled bool\n}\n\nfunc Show(s Settings) string { return fmt.Sprint(s.Port) }\n',
      },
    },
  ],
  // Every target's payments example: its adapters and domain code against
  // its generation plan and checked native bindings.
  ...[
    'clojure',
    'csharp',
    'elixir',
    'erlang',
    'fsharp',
    'gleam',
    'go',
    'groovy',
    'haskell',
    'java',
    'javascript',
    'kotlin',
    'prolog',
    'python',
    'rust',
    'scala',
    'swift',
    'typescript',
  ].map(language => [
    `advise-payments-${language}`,
    `payments-${language}`,
    [['advise', '--json']],
  ]),
  // The generated files must be current before a native test runs.
  ['program-test', 'haskell', [['test'], ['test', '--json']]],
  // lawspec doctor: toolchain probes through spawn and poll, the compiler
  // cache probe, and generation that waits for a ready toolchain.
  ['doctor', 'haskell', [['doctor'], ['doctor', '--json']]],
  [
    'doctor-artifacts',
    'artifacts',
    [
      ['doctor'],
      ['doctor', '--json'],
      ['doctor', '--no-cache'],
      ['doctor', '--target', 'yaml'],
    ],
  ],
  ['doctor-go', 'go', [['doctor'], ['doctor', '--json']], {requires: ['go']}],
  [
    'doctor-go-unresolved',
    'go',
    [['doctor']],
    {
      requires: ['go'],
      files: {'go.mod': 'module example.com/go\n\ngo 1.25.0\n', 'go.sum': null},
    },
  ],
  ['doctor-javascript', 'javascript', [['doctor'], ['doctor', '--json']]],
  [
    'doctor-javascript-commonjs',
    'javascript',
    [['doctor']],
    {files: {'package.json': '{"type": "commonjs"}\n'}},
  ],
  [
    'generate-go',
    'go',
    [
      ['generate', '--no-advice'],
      ['generate', '--no-advice', '--check'],
      ['generate', '--no-advice', '--json'],
    ],
    {requires: ['go']},
  ],
  // lawspec test: go test through spawn and poll, its JSON events, the
  // result cache (a passing law is unchanged until its key changes), the
  // failure database, tags, --fresh and the merged JUnit report.
  [
    'test-go',
    'go-laws',
    [
      ['generate', '--no-advice'],
      ['test', '--seed', '1'],
      ['test', '--seed', '1', '--json'],
      ['test', '--fresh', '--seed', '4', '--report', 'junit=reports/junit.xml'],
    ],
    {requires: ['go'], normalise: withoutRunTimes, normaliseFile: testResults},
  ],
  [
    'test-go-tags',
    'go-laws',
    [
      ['generate', '--no-advice'],
      ['test', '--seed', '1', '--tag', 'property'],
      ['test', '--seed', '2', '--exclude-tag', 'property', '--json'],
    ],
    {requires: ['go'], normalise: withoutRunTimes, normaliseFile: testResults},
  ],
  [
    'test-go-out-of-date',
    'go-laws',
    [
      ['test', '--seed', '1'],
      ['generate', '--no-advice'],
      {
        argv: ['test', '--seed', '1', '--json'],
        files: {'example/algebra/lawspec_test.go': 'package algebra\n'},
      },
    ],
    {requires: ['go'], normaliseFile: testResults},
  ],
  [
    'test-options',
    'go-laws',
    [
      ['test', '--report', 'xml=out.xml'],
      ['test', '--seed', '1', '--attestation', 'missing.json'],
      {
        argv: ['test', '--seed', '1', '--target', 'go'],
        files: {
          'lawspec.edn': manifest(
            '  :targets [{:language :go :root "."}]\n  :attestation "missing.json"\n  :verification {:layers [:property]}',
            'go',
          ),
        },
      },
    ],
  ],
  [
    'generate-javascript-unready',
    'javascript',
    [
      ['generate', '--no-advice'],
      ['generate', '--no-advice', '--json'],
    ],
  ],
  // lawspec mutate: each mutant on a scratch copy, tested in-process: one
  // the laws kill in a generated file, one they miss in the adapter, and a
  // malformed one; then a single mutant, and the option and path errors.
  [
    'mutate',
    'go-definitions',
    [
      ['generate', '--no-advice'],
      ['mutate', '--json', '--target', 'go'],
      ['mutate', 'mutants/adapter.mutant'],
      ['mutate', '--mutation-timeout', '0'],
      ['mutate', 'missing.mutant', '--json'],
    ],
    {
      requires: ['go'],
      files: {
        'mutants/increment.mutant':
          'expect: checked increment\n@@ example/refined_definitions/lawspec_definitions.go\n<<<<<<<\n\t\t\tlsBinary("+", x, lsInteger("Integer", "1")),\n=======\n\t\t\tlsBinary("+", x, lsInteger("Integer", "2")),\n>>>>>>>\n',
        'mutants/adapter.mutant':
          '@@ example/refined_definitions/adapter.go\n<<<<<<<\npackage refined_definitions\n=======\npackage refined_definitions\n\n// Mutated.\n>>>>>>>\n',
        'mutants/malformed.mutant': 'expect: nothing\n',
        'mutants/notes.txt': 'not a mutant\n',
      },
    },
  ],
  // A baseline whose laws fail runs no mutant.
  [
    'mutate-baseline-failed',
    'go-laws',
    [['generate', '--no-advice'], ['mutate']],
    {
      requires: ['go'],
      files: {
        'mutants/a.mutant':
          '@@ go.mod\n<<<<<<<\n*\n=======\nmodule example.com/other\n>>>>>>>\n',
      },
    },
  ],
  // lawspec lsp --stdio over the specifications, and a session whose
  // second message has no Content-Length, sent after the first is answered.
  ['lsp-session', 'specs', [{argv: ['lsp', '--stdio'], input: lspSession}]],
  [
    'lsp-invalid-length',
    'empty',
    [
      {
        argv: ['lsp', '--stdio'],
        input: ({cwd}) => [
          {
            data: framed({
              jsonrpc: '2.0',
              id: 1,
              method: 'initialize',
              params: {rootUri: `file://${cwd}`},
            }),
            until: '"id":1,',
          },
          {data: 'Content-Type: text/plain\r\n\r\n{}'},
        ],
      },
    ],
  ],
  // lawspec mcp: the handshake, the tool list and the project tools over
  // the specifications, invalid requests and arguments, then the end of
  // input; inspect and advise over a Go target; and a project tool where
  // there is no lawspec.edn.
  [
    'mcp-session',
    'specs',
    [
      {
        argv: ['mcp'],
        input: () =>
          [
            ...mcpOpening(),
            {jsonrpc: '2.0', id: 2, method: 'tools/list'},
            {jsonrpc: '2.0', id: 3, method: 'ping'},
            mcpCall(4, 'lawspec_list_laws', {}),
            mcpCall(5, 'lawspec_explain', {
              law: 'example.algebra::addition is commutative',
              view: 'math',
            }),
            mcpCall(6, 'lawspec_explain', {view: 'prose'}),
            mcpCall(7, 'lawspec_inspect', {target: 'go'}),
            mcpCall(8, 'lawspec_prelude', {query: 'commutative'}),
            {jsonrpc: '2.0', id: 9, method: 'resources/list'},
          ].map(mcpLine),
      },
      {
        argv: ['mcp'],
        input: () =>
          [
            {
              jsonrpc: '2.0',
              id: 1,
              method: 'initialize',
              params: {protocolVersion: 5, capabilities: []},
            },
            ...mcpOpening(4),
            {
              jsonrpc: '2.0',
              id: 'x',
              method: 'tools/call',
              params: {arguments: []},
            },
            mcpCall(2, 'lawspec_missing', {}),
            mcpCall(3, 'lawspec_check', {}),
          ]
            .map(mcpLine)
            .concat([
              {data: 'not json\n{"jsonrpc":"2.0","id":1.5,"method":"ping"}\n'},
            ]),
      },
    ],
  ],
  [
    'mcp-targets',
    'go',
    [
      {
        argv: ['mcp'],
        input: () =>
          [
            ...mcpOpening(),
            mcpCall(2, 'lawspec_inspect', {target: 'go'}),
            mcpCall(3, 'lawspec_advise', {target: 'go'}),
          ].map(mcpLine),
      },
    ],
  ],
  [
    'mcp-no-manifest',
    'empty',
    [
      {
        argv: ['mcp'],
        input: () =>
          [...mcpOpening(), mcpCall(2, 'lawspec_check', {})].map(mcpLine),
      },
    ],
  ],
];

// Every file below the root, except what a compiler build keeps in its own
// cache folder (named by 16 hexadecimal digits): that differs between the
// reference's build and the hosts' by design, so only its name is compared.
// With modes, each file's and directory's permission bits are compared too.
function tree(
  root,
  normaliseFile = (name, content) => [name, content],
  modes = false,
)
{
  const mode = file =>
    modes ? `${(lstatSync(file).mode & 0o7777).toString(8)} ` : '';
  const files = {};
  const visit = directory =>
  {
    for (const entry of readdirSync(directory, {withFileTypes: true}).sort(
      (a, b) => (a.name < b.name ? -1 : a.name > b.name ? 1 : 0),
    ))
    {
      const file = path.join(directory, entry.name);
      if (entry.isDirectory() && /^[0-9a-f]{16}$/.test(entry.name))
      {
        files[path.relative(root, directory) + '/<build>/'] = 'build';
      }
      // Solver receipts are named by the host's identity and record times.
      else if (entry.isDirectory() && entry.name === 'solver-goals-v1')
      {
        files[path.relative(root, file) + '/'] =
          `${readdirSync(file).length} receipt(s)`;
      }
      else if (entry.isDirectory())
      {
        if (modes)
        {
          files[path.relative(root, file) + '/'] = mode(file).trim();
        }
        visit(file);
      }
      else
      {
        const [name, content] = normaliseFile(
          path.relative(root, file),
          readFileSync(file),
          root,
        );
        files[name] = mode(file) + content.toString('base64');
      }
    }
  };
  visit(root);
  return files;
}

// Files by name: their content, null to remove one, or {content, mode}.
function place(directory, files = {})
{
  for (const [name, content] of Object.entries(files))
  {
    const file = path.join(directory, name);
    if (content === null)
    {
      rmSync(file, {force: true});
    }
    else
    {
      mkdirSync(path.dirname(file), {recursive: true});
      writeFileSync(file, content.content ?? content);
      if (content.mode !== undefined)
      {
        chmodSync(file, content.mode);
      }
    }
  }
}

function project(fixture, extraFiles)
{
  // The real path: a CLI reports its working directory as getcwd() does.
  const root = realpathSync(
    mkdtempSync(path.join(os.tmpdir(), 'lawspec-host-parity-')),
  );
  const cwd = fixtures[fixture](root);
  place(cwd, extraFiles);
  return {root, cwd};
}

// One process to its end: its output, its exit code and the signal that
// ended it, as spawnSync gives them. Standard input is a pipe that the
// invocation's input steps are written to, in order, before it is closed;
// without any it is empty and closed at once, as spawnSync's is. A step
// with until is followed by a wait until standard output contains that
// text, so a server answers each request before the next one, or the end
// of its input, arrives; a server that never writes it fails the case
// after the wait's bound.
const inputWaitMilliseconds = 120000;
function execute(program, args, options, input = [])
{
  return new Promise((resolve, reject) =>
  {
    const child = spawn(program, args, options);
    const stdout = [];
    const stderr = [];
    let waiting = null;
    child.stdout.on('data', chunk =>
    {
      stdout.push(chunk);
      waiting?.();
    });
    child.stderr.on('data', chunk => stderr.push(chunk));
    child.on('error', reject);
    child.on('close', (status, signal) =>
    {
      waiting?.();
      resolve({
        stdout: Buffer.concat(stdout),
        stderr: Buffer.concat(stderr),
        status,
        signal,
      });
    });
    child.stdin.on('error', () =>
    {});
    const written = text =>
      new Promise(done =>
      {
        const timer = setTimeout(finish, inputWaitMilliseconds);
        function finish()
        {
          clearTimeout(timer);
          waiting = null;
          done();
        }
        waiting = () =>
        {
          if (
            child.exitCode !== null ||
            child.signalCode !== null ||
            Buffer.concat(stdout).includes(text)
          )
          {
            finish();
          }
        };
        waiting();
      });
    (async () =>
    {
      for (const {data, until} of input)
      {
        child.stdin.write(data);
        if (until !== undefined)
        {
          await written(until);
        }
      }
      child.stdin.end();
    })();
  });
}

// What one runner did in one case: each invocation's output and exit code,
// with the temporary root's path replaced, and the files left behind.
async function observe(command, fixture, invocations, settings)
{
  const {root, cwd} = project(fixture, settings.files);
  try
  {
    const steps = [];
    let milliseconds = 0;
    for (const invocation of invocations)
    {
      const {
        argv,
        env = {},
        files,
        input,
        serve,
      } = Array.isArray(invocation) ? {argv: invocation} : invocation;
      place(cwd, files);
      const [program, args, environment] = command(
        argv.map(argument =>
          argument === '<z3>'
            ? tools.z3
            : argument === '<busy>'
              ? busyPort
              : argument,
        ),
      );
      const started = performance.now();
      const result = serve
        ? await serveSession(
            program,
            args,
            {cwd, env: {...environment, ...env}},
            serve,
          )
        : await execute(
            program,
            args,
            {cwd, env: {...environment, ...env}},
            input?.({root, cwd}),
          );
      milliseconds += performance.now() - started;
      const normalise = settings.normalise ?? (text => text);
      steps.push({
        stdout: normalise(result.stdout.toString().replaceAll(root, '<root>')),
        stderr: normalise(result.stderr.toString().replaceAll(root, '<root>')),
        exit: result.status,
        signal: result.signal,
        ...(result.responses ? {responses: result.responses} : {}),
      });
    }
    return {
      steps,
      files: JSON.stringify(tree(root, settings.normaliseFile, settings.modes)),
      milliseconds,
    };
  }
  finally
  {
    rmSync(root, {recursive: true, force: true});
  }
}

// The lines that report one case, once each runner has observed it. Every
// runner must match the reference, the native CLI; a case with an expect
// list must also print exactly that, the reference included.
function report(name, settings, observed)
{
  const lines = [];
  const reference = observed.native;
  const expected =
    settings.expect?.map(expectation => expectation.step) ?? reference.steps;
  const same = runner =>
    JSON.stringify(observed[runner].steps) === JSON.stringify(expected) &&
    observed[runner].files === reference.files;
  const compared = Object.keys(runners).filter(
    runner => runner !== 'native' || settings.expect,
  );
  const different = compared.filter(runner => !same(runner));
  if (different.length)
  {
    lines.push(
      `FAIL ${name}: ${different.join(', ')} differ from ${settings.expect ? 'the expected output' : 'native'}`,
    );
    const filesDiffer = different.some(
      runner => observed[runner].files !== reference.files,
    );
    for (const runner of [...new Set(['native', ...different])])
    {
      lines.push(
        `  ${runner}: ${JSON.stringify(observed[runner].steps).slice(0, 1200)}`,
      );
      if (filesDiffer)
      {
        lines.push(
          `  ${runner} files: ${Object.keys(JSON.parse(observed[runner].files)).join(' ')}`,
        );
      }
    }
  }
  else
  {
    lines.push(
      `ok ${name} (exit ${reference.steps.map(step => step.exit ?? step.signal).join(', ')})`,
    );
  }
  return {failed: different.length > 0, lines};
}

const selected = cases.filter(([name]) => selects(name));
if (selected.length === 0)
{
  throw new Error(`no case matches ${only}`);
}
// The Go host compiles its core on its first run into wazero's compilation
// cache, which every later run reads, and the JVM launcher unpacks its jars
// into its cache on its first run. Filling each once here, before the runs
// start together, keeps them from each doing it at once.
for (const runner of ['go-host', 'jvm-host'].filter(name => runners[name]))
{
  const scratch = realpathSync(
    mkdtempSync(path.join(os.tmpdir(), 'lawspec-host-parity-')),
  );
  try
  {
    const [command, arguments_, env] = runners[runner](['--version']);
    spawnSync(command, arguments_, {cwd: scratch, env, stdio: 'ignore'});
  }
  finally
  {
    rmSync(scratch, {recursive: true, force: true});
  }
}
// Every runner's run of every case is a job; the cases marked slow (the
// longest, in a profile of the whole run) start first, so that they do not
// finish last alone.
const outcomes = selected.map(() => ({observed: {}, pending: 0}));
const work = [];
selected.forEach(([name, fixture, invocations, settings = {}], index) =>
{
  const absent = (settings.requires ?? []).filter(tool => !tools[tool]);
  if (absent.length)
  {
    outcomes[index].lines = [`skipped ${name}: ${absent.join(', ')} absent`];
    outcomes[index].skipped = true;
    return;
  }
  for (const [runner, command] of Object.entries(runners))
  {
    outcomes[index].pending++;
    work.push({
      index,
      slow: settings.slow ?? 0,
      run: async () =>
      {
        outcomes[index].observed[runner] = await observe(
          command,
          fixture,
          invocations,
          settings,
        );
      },
    });
  }
});
work.sort((a, b) => b.slow - a.slow || a.index - b.index);

let failures = 0;
let skipped = 0;
let reported = 0;
// Reports each finished case in case order: a case waits for those before it.
const flush = () =>
{
  while (reported < selected.length && outcomes[reported].pending === 0)
  {
    const outcome = outcomes[reported];
    const [name, , , settings = {}] = selected[reported];
    if (outcome.skipped)
    {
      skipped++;
    }
    else
    {
      const {failed, lines} = report(name, settings, outcome.observed);
      outcome.lines = lines;
      failures += failed ? 1 : 0;
    }
    for (const line of outcome.lines)
    {
      console.log(line);
    }
    reported++;
  }
};
const started = performance.now();
const loadBefore = os.loadavg();
let next = 0;
await Promise.all(
  Array.from({length: Math.min(jobs, work.length)}, async () =>
  {
    while (next < work.length)
    {
      const job = work[next++];
      await job.run();
      outcomes[job.index].pending--;
      flush();
    }
  }),
);
flush();

// Where the time went: each runner's total, and the cases that took
// longest over all runners.
const timings = {};
const caseTimes = [];
selected.forEach(([name], index) =>
{
  let total = 0;
  for (const [runner, observed] of Object.entries(outcomes[index].observed))
  {
    timings[runner] = (timings[runner] ?? 0) + observed.milliseconds;
    total += observed.milliseconds;
  }
  caseTimes.push([name, total]);
});
for (const [runner, milliseconds] of Object.entries(timings))
{
  console.log(`time ${runner}: ${(milliseconds / 1000).toFixed(1)} s`);
}
for (const [name, milliseconds] of caseTimes
  .sort((a, b) => b[1] - a[1])
  .slice(0, 12))
  {
  console.log(`time case ${name}: ${(milliseconds / 1000).toFixed(1)} s`);
}
console.log(
  `time wall: ${((performance.now() - started) / 1000).toFixed(1)} s with ${jobs} job(s); load average ${[
    loadBefore,
    os.loadavg(),
  ]
    .map(loads => loads.map(load => load.toFixed(1)).join(' '))
    .join(' before, ')} after`,
);
const ran = selected.length - skipped;
const skippedText = skipped
  ? `; ${skipped} skipped for an absent toolchain`
  : '';
console.log(
  failures
    ? `${failures} of ${ran} case(s) differ${skippedText}.`
    : `All hosts agree on ${ran} case(s)${skippedText}.`,
);
busy.close();
process.exitCode = failures ? 1 : 0;
