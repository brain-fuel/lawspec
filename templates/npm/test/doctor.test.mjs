import {configEDN} from './manifest-fixtures.mjs';
import {test} from 'node:test';
import assert from 'node:assert/strict';
import {mkdtemp, readFile, writeFile, rm, readdir} from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import {execFile} from 'node:child_process';
import {promisify} from 'node:util';
import {supported, doctor} from '../doctor.mjs';
const exec = promisify(execFile);
test('compatibility profiles enforce Java 21 and Python 3.13 floors', () =>
{
  for (const version of ['5.14.0', '5.14.4', '6.0.3'])
    assert.equal(supported('java', 'junit-jupiter', version), true, version);
  for (const version of ['5.13.4', '6.1.0', '6.0.0-RC1', '7.0.0'])
    assert.equal(supported('java', 'junit-jupiter', version), false, version);
  assert.equal(supported('java', 'java', '20.0.2'), false);
  assert.equal(supported('java', 'java', '21.0.5'), true);
  assert.equal(supported('java', 'java', '25.0.4'), true);
  assert.equal(supported('python', 'python', '3.12.12'), false);
  assert.equal(supported('python', 'python', '3.13.15'), true);
  assert.equal(supported('python', 'python', '3.13.0rc1'), false);
  assert.equal(supported('python', 'hypothesis', '6.0.0'), false);
});
test('incompatible or unverifiable environments prevent generation writes', async t =>
{
  const root = await mkdtemp(path.join(os.tmpdir(), 'lawspec-doctor-'));
  t.after(() => rm(root, {recursive: true, force: true}));
  const executable = path.join(root, 'python');
  const config = {
    manifestVersion: 1,
    languageProfile: '1.0-rc.2',
    verification: {layers: []},
    sources: ['codec.lawspec'],
    targets: [{language: 'python', root: '.', python: executable}],
  };
  await writeFile(path.join(root, 'lawspec.edn'), configEDN(config));
  await writeFile(
    path.join(root, 'codec.lawspec'),
    await readFile(new URL('../starter-rc1.lawspec', import.meta.url), 'utf8'),
  );
  for (const version of ['3.12.15', 'unknown'])
  {
    const report = {
      python: version,
      pytest: '8.4.2',
      hypothesis: '6.135.26',
      config: {pythonpath: ['src'], testpaths: ['tests']},
    };
    await writeFile(
      executable,
      `#!${process.execPath}\nconsole.log(${JSON.stringify(JSON.stringify(report))});\n`,
      {mode: 0o755},
    );
    const before = (await readdir(root)).sort();
    assert.equal((await doctor(config.targets[0], root)).ok, false);
    await assert.rejects(
      exec(
        process.execPath,
        [new URL('../bin/lawspec.mjs', import.meta.url).pathname, 'generate'],
        {cwd: root},
      ),
      e => e.code === 1 && /python/.test(e.stdout + e.stderr),
    );
    assert.deepEqual((await readdir(root)).sort(), before);
    assert.equal(
      await readFile(path.join(root, 'lawspec.edn'), 'utf8'),
      configEDN(config),
    );
  }
});

test('a build tool that is not installed is a doctor finding, not a spawn error', async t =>
{
  const root = await mkdtemp(path.join(os.tmpdir(), 'lawspec-doctor-'));
  t.after(() => rm(root, {recursive: true, force: true}));
  const cases = [
    ['java', {maven: 'lawspec-no-such-mvn'}, 'lawspec-no-such-mvn'],
    ['kotlin', {gradle: 'lawspec-no-such-gradle'}, 'lawspec-no-such-gradle'],
    ['groovy', {gradle: './gradlew'}, './gradlew'],
  ];
  for (const [language, tool, command] of cases)
  {
    const report = await doctor({language, root: '.', ...tool}, root);
    assert.equal(report.ok, false);
    assert.ok(
      report.message.startsWith(`${command} was not found`),
      report.message,
    );
    assert.match(report.message, /; (?:searched|looked for) /);
    assert.doesNotMatch(report.message, /ENOENT|EINVAL/);
    assert.ok(report.instructions);
  }
});

test('Rapid accepts both stable baselines and rejects unsupported versions', () =>
{
  for (const version of ['1.2.0', 'v1.3.0', '1.3.1'])
    assert.equal(supported('go', 'rapid', version), true);
  for (const version of ['1.1.0', '1.4.0', '1.3.0-rc.1', 'local', ''])
    assert.equal(supported('go', 'rapid', version), false);
});

test('Go doctor applies the shared Rapid range to resolved modules', async t =>
{
  const root = await mkdtemp(path.join(os.tmpdir(), 'lawspec-go-doctor-'));
  t.after(() => rm(root, {recursive: true, force: true}));
  await writeFile(
    path.join(root, 'go'),
    `#!${process.execPath}
if (process.argv[2] === 'version') console.log('go version go1.25.0 darwin/arm64');
else if (process.argv.includes('-json')) console.log(JSON.stringify({
  Version: process.env.RAPID_TEST_VERSION,
  ...(process.env.RAPID_TEST_REPLACE ? {Replace: {Dir: '/local'}} : {}),
}));
`,
    {mode: 0o755},
  );
  const module = new URL('../doctor.mjs', import.meta.url).href;
  const code = `import {doctor} from ${JSON.stringify(module)}; console.log(JSON.stringify(await doctor({language:'go'},process.cwd())));`;
  for (const [version, replacement, expected] of [
    ['v1.2.0', '', true],
    ['v1.3.0', '', true],
    ['v1.3.0', 'local', false],
    ['v1.4.0', '', false],
    ['v1.3.0-rc.1', '', false],
  ])
  {
    const {stdout} = await exec(
      process.execPath,
      ['--input-type=module', '-e', code],
      {
        cwd: root,
        env: {
          ...process.env,
          PATH: root + path.delimiter + process.env.PATH,
          RAPID_TEST_VERSION: version,
          RAPID_TEST_REPLACE: replacement,
        },
      },
    );
    assert.equal(JSON.parse(stdout).ok, expected, `${version} ${replacement}`);
  }
});

// A stand-in for Maven that answers the three questions doctor asks it.
async function fakeMaven(t, answers)
{
  const root = await mkdtemp(path.join(os.tmpdir(), 'lawspec-java-doctor-'));
  t.after(() => rm(root, {recursive: true, force: true}));
  const pom = ({release = 25, plugins = ''} = {}) => `<project>
  <properties>
    <maven.compiler.release>${release}</maven.compiler.release>
  </properties>
  <build>
    <sourceDirectory>${path.join(root, 'src/main/java')}</sourceDirectory>
    <testSourceDirectory>${path.join(root, 'src/test/java')}</testSourceDirectory>
    <plugins>
      <plugin>
        <artifactId>maven-compiler-plugin</artifactId>
        <version>3.14.1</version>
      </plugin>
      <plugin>
        <artifactId>maven-surefire-plugin</artifactId>
        <version>3.5.4</version>
      </plugin>${plugins}
    </plugins>
  </build>
</project>`;
  // Lines as mvn dependency:tree -Dscope=test -DoutputType=text prints them.
  const tree = ({
    declared = '5.14.0',
    resolved = declared,
    engine = resolved,
  } = {}) =>
    [
      '[INFO] example:laws:jar:0.1.0',
      '[INFO] +- org.jetbrains:jetCheck:jar:0.3.0:test',
      `[INFO] \\- org.junit.jupiter:junit-jupiter:jar:${declared}:test`,
      `[INFO]    +- org.junit.jupiter:junit-jupiter-api:jar:${resolved}:test`,
      `[INFO]    +- org.junit.jupiter:junit-jupiter-params:jar:${resolved}:test`,
      `[INFO]    \\- org.junit.jupiter:junit-jupiter-engine:jar:${engine}:test`,
    ].join('\n');
  const maven = path.join(root, 'mvn');
  const set = async ({java = '25.0.4', ...rest} = {}) =>
    writeFile(
      path.join(root, 'mvn.json'),
      JSON.stringify({java, pom: pom(rest), tree: tree(rest)}),
    );
  await writeFile(
    maven,
    `#!${process.execPath}
const answers = JSON.parse(require('node:fs').readFileSync(${JSON.stringify(path.join(root, 'mvn.json'))}, 'utf8'));
const goal = process.argv[2];
if (goal === '-version') console.log('Apache Maven 3.9.16\\nJava version: ' + answers.java + ', vendor: Test');
else if (goal === 'help:effective-pom') console.log(answers.pom);
else if (goal === 'dependency:tree') console.log(answers.tree);
else process.exit(2);
`,
    {mode: 0o755},
  );
  await set(answers);
  return {root, maven, set};
}

test('Java doctor reads the JUnit version Maven resolved, not the one declared', async t =>
{
  const {root, maven, set} = await fakeMaven(t);
  const target = {language: 'java', root: '.', maven};
  const ready = await doctor(target, root);
  assert.equal(ready.ok, true, ready.message);
  assert.equal(ready.versions['junit-jupiter'], '5.14.0');
  // Spring Boot 4's BOM manages JUnit: a dependency that declares 5.14.0
  // still resolves the 6.0.3 API and engine beneath it.
  await set({declared: '5.14.0', resolved: '6.0.3'});
  const managed = await doctor(target, root);
  assert.equal(managed.ok, true, managed.message);
  assert.equal(managed.versions['junit-jupiter'], '6.0.3');
  // The API and the engine that runs it must be one release.
  await set({declared: '5.14.0', resolved: '6.0.3', engine: '5.14.0'});
  const mixed = await doctor(target, root);
  assert.equal(mixed.ok, false);
  assert.match(
    mixed.message,
    /junit-jupiter-engine 5\.14\.0 beside junit-jupiter-api 6\.0\.3/,
  );
  // An unsupported release names what was resolved and how to pin it.
  await set({declared: '5.14.0', resolved: '5.12.2'});
  const older = await doctor(target, root);
  assert.equal(older.ok, false);
  assert.match(older.message, /resolves junit-jupiter-api 5\.12\.2/);
  assert.match(older.message, /org\.junit:junit-bom/);
  assert.match(older.message, /before that BOM/);
});

test('Java doctor checks the release the target chose', async t =>
{
  const {root, maven, set} = await fakeMaven(t, {release: 21, java: '21.0.5'});
  const chosen = await doctor(
    {language: 'java', root: '.', maven, release: 21},
    root,
  );
  assert.equal(chosen.ok, true, chosen.message);
  const unset = await doctor({language: 'java', root: '.', maven}, root);
  assert.equal(unset.ok, false);
  assert.match(unset.message, /Maven must run on Java 25\+/);
  await set({release: 21, java: '25.0.4'});
  const mismatch = await doctor({language: 'java', root: '.', maven}, root);
  assert.equal(mismatch.ok, false);
  assert.match(mismatch.message, /release must be 25; set :release 21/);
  await set({release: 25, java: '25.0.4'});
  const behind = await doctor(
    {language: 'java', root: '.', maven, release: 21},
    root,
  );
  assert.equal(behind.ok, false);
  assert.match(behind.message, /release must be 21/);
  const unsupported = await doctor(
    {language: 'java', root: '.', maven, release: 17},
    root,
  );
  assert.equal(unsupported.ok, false);
  assert.match(
    unsupported.message,
    /release 17 is not supported for java; choose 21 or 25/,
  );
});

test('Java doctor requires the build to compile the generated directories', async t =>
{
  const {root, maven, set} = await fakeMaven(t);
  const target = {
    language: 'java',
    root: '.',
    maven,
    generatedSourceDir: 'target/generated-sources/lawspec',
    generatedTestDir: 'target/generated-test-sources/lawspec',
  };
  const missing = await doctor(target, root);
  assert.equal(missing.ok, false);
  assert.match(
    missing.message,
    /Maven must compile the target's generated directories/,
  );
  assert.match(missing.message, /<goal>add-source<\/goal>/);
  assert.match(
    missing.message,
    /<source>\$\{project\.basedir\}\/target\/generated-test-sources\/lawspec<\/source>/,
  );
  // The effective POM shows the executions with their paths made absolute.
  const execution = (goal, body) => `
          <execution>
            <goals>
              <goal>${goal}</goal>
            </goals>
            <configuration>${body}</configuration>
          </execution>`;
  const helper = executions => `
      <plugin>
        <artifactId>build-helper-maven-plugin</artifactId>
        <executions>${executions}
        </executions>
      </plugin>`;
  const sources = execution(
    'add-source',
    `<sources><source>${path.join(root, target.generatedSourceDir)}</source></sources>`,
  );
  const tests = execution(
    'add-test-source',
    `<sources><source>${path.join(root, target.generatedTestDir)}</source></sources>`,
  );
  const resources = execution(
    'add-test-resource',
    `<resources><resource><directory>${path.join(root, target.generatedTestDir)}</directory></resource></resources>`,
  );
  await set({plugins: helper(sources)});
  assert.equal((await doctor(target, root)).ok, false);
  await set({plugins: helper(sources + tests)});
  const registered = await doctor(target, root);
  assert.equal(registered.ok, true, registered.message);
  // A harness's JUnit configuration is a test resource in that directory.
  const planned = [
    {path: `${target.generatedTestDir}/example/SlugLawSpecTest.java`},
    {path: `${target.generatedTestDir}/junit-platform.properties`},
  ];
  assert.equal((await doctor(target, root, planned)).ok, false);
  await set({plugins: helper(sources + tests + resources)});
  const complete = await doctor(target, root, planned);
  assert.equal(complete.ok, true, complete.message);
});

test('haskell: a project never built is told to build it, before Stack runs', async t =>
{
  const root = await mkdtemp(path.join(os.tmpdir(), 'lawspec-doctor-haskell-'));
  t.after(() => rm(root, {recursive: true, force: true}));
  await writeFile(path.join(root, 'package.yaml'), 'name: example\n');
  const report = await doctor({language: 'haskell'}, root);
  assert.equal(report.ok, false);
  assert.match(JSON.stringify(report), /has no \.cabal file yet/);
  assert.match(JSON.stringify(report), /stack build --test --no-run-tests/);
});
