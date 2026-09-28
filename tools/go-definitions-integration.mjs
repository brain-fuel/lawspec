import assert from 'node:assert/strict';
import {execFileSync, spawnSync} from 'node:child_process';
import {mkdir, mkdtemp, readFile, writeFile, rm} from 'node:fs/promises';
import path from 'node:path';
import {planWrites, applyWrites} from '../npm/files.mjs';

const root = path.resolve(import.meta.dirname, '..');
const compiler = process.env.LAWSPEC_CORE;
const fixture = process.env.LAWSPEC_GO_DEFINITIONS_FIXTURE;
assert.ok(compiler && fixture, 'Set LAWSPEC_CORE and LAWSPEC_GO_DEFINITIONS_FIXTURE');
const rapid = process.env.LAWSPEC_RAPID ?? path.join(
  execFileSync('go', ['env', 'GOMODCACHE'], {encoding: 'utf8'}).trim(), 'pgregory.net/rapid@v1.2.0');
const env = {...process.env, GOCACHE: path.join(root, '.artifacts/go-cache'), GOTOOLCHAIN: 'local', GOPROXY: 'off'};
const source = await readFile(path.join(root, 'test/fixtures/total_definitions.lawspec'), 'utf8');
const other = `unit other
type Pair (a :: Type) (b :: Type) is Pair first :: a second :: b end
definition genericIdentity (x :: a) :: a is x end
definition genericCount (xs :: List a) :: BigInt is match xs with | Nil -> 0 | Cons head tail -> 1 + genericCount tail end end
law \`generic booleans\` is definition is \`for all\` (xs :: List Bool) . genericCount xs = prelude.length xs end end
law \`generic texts\` is definition is \`for all\` (xs :: List Text where genericCount xs > 0) . genericCount xs = prelude.length xs end end
definition size (x :: Bool) :: Bool is genericIdentity x end
definition pairCount (xs :: List (Pair Int8 Bool)) :: BigInt is genericCount xs end
law \`count products\` is definition is \`for all\` (xs :: List (Pair Int8 Bool)) . pairCount xs = prelude.length xs end end
`;
for (const machineBits of [32, 64]) {
  const sourceDir = machineBits === 32 ? 'library/native' : '';
  const sources = [{path: 'total.lawspec', content: source}, {path: 'other.lawspec', content: other}];
  const result = JSON.parse(execFileSync(compiler, [], {input: JSON.stringify({
    method: 'planGeneration', target: 'go', machineBits, sourceDir, testDir: sourceDir, sources,
  }), encoding: 'utf8', maxBuffer: 32 * 1024 * 1024}));
  assert.deepEqual(result.diagnostics, []);
  const directory = path.join(root, `.artifacts/go-definitions/${machineBits}`);
  const nativeDirectory = path.join(directory, 'native-only');
  const generated = [];
  let adapter;
  let adapterSource;
  for (const file of result.files) {
    const destination = path.join(directory, file.path);
    await mkdir(path.dirname(destination), {recursive: true});
    let content = file.content;
    if (file.ownership === 'user' && file.path.endsWith('example/total/adapter.go')) {
      assert.doesNotMatch(content, /func (Size|SumList|SumTree|Increment)\(/);
      content = content.replace('panic("actualSum")', 'result := new(LawSpecBigInt); for _, x := range value0 { result.Add(result, new(LawSpecBigInt).SetInt64(int64(x))) }; return result')
        .replace('panic("actualIncrement")', 'return new(LawSpecBigInt).SetInt64(int64(value0) + 1)')
        .replace('panic("actualTree")', 'switch value := value0.(type) { case TreeLeaf: return new(LawSpecBigInt).SetInt64(int64(value.Value)); case TreeBranch: return new(LawSpecBigInt).Add(ActualTree(value.Left), ActualTree(value.Right)); default: panic("invalid tree") }');
      adapter = file;
      adapterSource = content;
    }
    if (file.path.endsWith('/lawspec_test.go')) {
      assert.equal(execFileSync('gofmt', [], {input: content, encoding: 'utf8',
        maxBuffer: 32 * 1024 * 1024}), content, `${file.path}: property file must match gofmt`);
    }
    if (file.path.endsWith('/lawspec_definitions.go')) {
      assert.equal(file.ownership, 'generated');
      assert.equal(file.placement, 'source');
      const formatted = execFileSync('gofmt', [], {input: content, encoding: 'utf8'});
      if (formatted !== content) {
        await writeFile(destination, content);
        await writeFile(`${destination}.formatted`, formatted);
        assert.fail(`gofmt mismatch: ${destination}`);
      }
      generated.push({file, destination, content});
    }
    await writeFile(destination, content);
    if (file.placement === 'source') {
      assert.doesNotMatch(content, /pgregory.net\/rapid/);
      const nativePath = path.join(nativeDirectory, file.path);
      await mkdir(path.dirname(nativePath), {recursive: true});
      await writeFile(nativePath, content);
    }
  }
  assert.equal(generated.length, 2);
  await writeFile(path.join(nativeDirectory, 'go.mod'), 'module definitions-native\n\ngo 1.24\n');
  const nativeCheck = await readFile(path.join(root, 'test/runtime/GoDefinitionsCheck.go'), 'utf8');
  const packageDir = path.join(sourceDir, 'example/total');
  await writeFile(path.join(nativeDirectory, packageDir, 'definitions_test.go'), `${nativeCheck}\nconst profileBits = ${machineBits}\n`);
  await writeFile(path.join(nativeDirectory, sourceDir, 'other', 'definitions_test.go'), `package other
import "testing"
func TestOther(t *testing.T) {
 symbols := map[string]*LawSpecSymbol{}
 if !LawSpecDefinitions.Size(symbols, true) || LawSpecDefinitions.PairCount(symbols, []Pair[int8, bool]{PairPair[int8, bool]{First: 127, Second: true}}).Int64() != 1 { t.Fatal("native product or duplicate function") }
}
`);
  function native() {
    execFileSync('go', ['test', '-count=1', './...'], {cwd: nativeDirectory, env, stdio: 'inherit'});
  }
  native();
  for (const [index, expression] of [
    'LawSpecDefinitions.Size(symbols, []string{"bad"})', 'LawSpecDefinitions.SumTree(symbols, true)',
    'LawSpecDefinitions.MaybeDefault(symbols, LawSpecJust(true))', 'LawSpecDefinitions.Absent(symbols, LawSpecOptional[bool]{})',
  ].entries()) {
    const badFile = path.join(nativeDirectory, packageDir, 'bad_call.go');
    await writeFile(badFile, `package total\nfunc badCall() { symbols := map[string]*LawSpecSymbol{}; _ = ${expression} }\n`);
    const bad = spawnSync('go', ['test', './...'], {cwd: nativeDirectory, env, encoding: 'utf8'});
    await writeFile(path.join(directory, `negative-${index}.log`), bad.stdout + bad.stderr);
    assert.notEqual(bad.status, 0);
    assert.match(bad.stdout + bad.stderr, /cannot use|does not implement/);
    await rm(badFile);
  }
  await writeFile(path.join(directory, 'go.mod'), `module definitions\n\ngo 1.24\nrequire pgregory.net/rapid v1.2.0\nreplace pgregory.net/rapid => ${rapid}\n`);
  async function run(label) {
    const result = spawnSync('go', ['test', '-count=1', ...(sourceDir ? [`./${sourceDir}/...`] : ['./example/...', './other/...'])], {
      cwd: directory, env, encoding: 'utf8', maxBuffer: 32 * 1024 * 1024,
    });
    const log = (result.stdout ?? '') + (result.stderr ?? '');
    await writeFile(path.join(directory, `${label}.log`), log);
    return {...result, log};
  }
  const correct = await run('correct');
  assert.equal(correct.status, 0, correct.log);
  const compactPlan = JSON.parse(execFileSync(compiler, [], {input: JSON.stringify({
    method: 'planGeneration', target: 'go', machineBits, minify: true, sourceDir, testDir: sourceDir, sources,
  }), encoding: 'utf8', maxBuffer: 32 * 1024 * 1024}));
  assert.deepEqual(compactPlan.diagnostics, []);
  for (const file of compactPlan.files.filter(file => file.ownership === 'generated')) {
    await writeFile(path.join(directory, file.path), file.content);
  }
  const compactProperties = await run('compact-properties');
  assert.equal(compactProperties.status, 0, compactProperties.log);
  for (const file of result.files.filter(file => file.ownership === 'generated')) {
    await writeFile(path.join(directory, file.path), file.content);
  }
  for (const [label, from, to] of [
    ['sum', 'result.Add(result, new(LawSpecBigInt).SetInt64(int64(x)))', '_ = x'],
    ['overflow', 'int64(value0) + 1', 'int64(value0 + 1)'],
    ['tree', 'new(LawSpecBigInt).Add(ActualTree(value.Left), ActualTree(value.Right))', 'new(LawSpecBigInt)'],
  ]) {
    const mutation = adapterSource.replace(from, to);
    assert.notEqual(mutation, adapterSource);
    await writeFile(path.join(directory, adapter.path), mutation);
    const result = await run(label);
    assert.notEqual(result.status, 0, `mutant exposed: ${label}`);
    assert.match(result.log, /expect/);
    assert.doesNotMatch(result.log, /build failed|undefined:|syntax error/);
  }
  await writeFile(path.join(directory, adapter.path), adapterSource);
  const sourcePaths = [];
  for (const item of sources) {
    const file = path.join(directory, item.path);
    await writeFile(file, item.content);
    sourcePaths.push(file);
  }
  execFileSync(fixture, [String(machineBits), directory, sourceDir, ...sourcePaths]);
  assert.ok((await readFile(generated[0].destination, 'utf8')).length < generated[0].content.length);
  for (const item of generated) {
    await writeFile(path.join(nativeDirectory, item.file.path), await readFile(item.destination, 'utf8'));
  }
  native();
  const compact = await run('compact');
  assert.equal(compact.status, 0, compact.log);
  for (const item of generated) await writeFile(item.destination, item.content);
  const regeneration = await mkdtemp(path.join(directory, 'regeneration-'));
  await applyWrites([await planWrites(regeneration, result.files)]);
  await writeFile(path.join(regeneration, adapter.path), adapterSource);
  assert.equal((await planWrites(regeneration, result.files)).changes.length, 0);
  await writeFile(path.join(regeneration, generated[0].file.path), '// edited generated definition\n');
  await assert.rejects(planWrites(regeneration, result.files), /edited generated file/);
  console.log(`Go definitions, native types, profiles, properties, compact source, ownership and mutants passed: ${machineBits}`);
}
