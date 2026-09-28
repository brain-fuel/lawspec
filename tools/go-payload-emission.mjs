// Compile untouched Core emission and execute native APIs and Rapid properties.
import assert from 'node:assert/strict';
import {execFileSync, spawnSync} from 'node:child_process';
import {mkdir, readFile, readdir, writeFile} from 'node:fs/promises';
import path from 'node:path';
const root = path.resolve(import.meta.dirname, '..');
const fixture = process.env.LAWSPEC_PAYLOAD_FIXTURE;
assert.ok(fixture, 'Set LAWSPEC_PAYLOAD_FIXTURE');
const rapid = path.join(execFileSync('go', ['env', 'GOMODCACHE'], {encoding: 'utf8'}).trim(),
  'pgregory.net/rapid@v1.2.0');
const env = {...process.env, GOCACHE: path.join(root, '.artifacts/go-cache'),
  GOTOOLCHAIN: 'local', GOPROXY: 'off'};
const syntaxChecker = path.join(root, '.artifacts/go-payload-syntax-check');
execFileSync('go', ['build', '-o', syntaxChecker, path.join(root, 'tools/GoSyntaxCheck.go')], {env});
const pairs = [];
const nativeCheck = `package payload
import (
  "fmt"
  "strings"
  "testing"
)
func TestNativePayloads(t *testing.T) {
  symbols := map[string]*LawSpecSymbol{}
  var value Tree[int8] = TreeNode[int8]{Children: []Tree[int8]{
    TreeLeaf[int8]{Value: 2, Fixed: -128}, TreeLeaf[int8]{Value: 3, Fixed: 0},
  }}
  if !LawSpecDefinitions.Above(symbols, value, 1) || LawSpecDefinitions.Above(symbols, value, 2) {
    t.Fatal("captured threshold or fixed field affected traversal")
  }
  if !LawSpecDefinitions.Positive(symbols, nil) || LawSpecDefinitions.Positive(symbols, []int8{1, 0}) {
    t.Fatal("empty or rejected payload")
  }
  LawSpecDefinitions.Identity(symbols, PackPack{Tree: value})
  LawSpecDefinitions.GenericIdentity(symbols, GenericPackGenericPack[int8]{Tree: value})
  symbol := func(id string) *LawSpecSymbol {
    return lsSymbol(id, "description", symbols).Data.(*LawSpecSymbol)
  }
  if !LawSpecDefinitions.Shared(symbols, []*LawSpecSymbol{symbol("shared")}) ||
    LawSpecDefinitions.Shared(symbols, []*LawSpecSymbol{symbol("different")}) {
    t.Fatal("Symbol identity lost")
  }
  defer func() {
    problem := recover()
    if problem == nil || !strings.Contains(fmt.Sprint(problem), "constructor field contract rejected") {
      t.Fatalf("expected contextual constructor rejection, got %v", problem)
    }
  }()
  LawSpecDefinitions.Identity(symbols, PackPack{Tree: TreeLeaf[int8]{Value: 0}})
}
`;
for (const bits of [32, 64]) for (const builtins of [false, true]) {
  const readable = new Map();
  for (const compact of [false, true]) {
    const directory = path.join(root, `.artifacts/go-payload-emission/${bits}-${compact}-${builtins}`);
    execFileSync(fixture, [String(bits), compact ? 'True' : 'False', directory, 'go',
      ...(builtins ? ['builtins'] : [])]);
    const project = path.join(directory, 'payload');
    for (const name of (await readdir(project)).filter(name => name.endsWith('.go') && name !== 'native_payload_test.go')) {
      const file = path.join(project, name);
      const content = await readFile(file, 'utf8');
      const formatted = execFileSync('gofmt', [], {input: content, encoding: 'utf8'});
      if (!compact) {
        assert.equal(content, formatted, file);
        readable.set(name, file);
      } else {
        assert.ok(readable.has(name));
        pairs.push({Readable: readable.get(name), Compact: file});
      }
    }
    await writeFile(path.join(directory, 'go.mod'),
      'module fixture\n\ngo 1.24.0\n\nrequire pgregory.net/rapid v1.2.0\nreplace pgregory.net/rapid => ' +
      JSON.stringify(rapid) + '\n');
    if (!builtins) await writeFile(path.join(project, 'native_payload_test.go'), nativeCheck);
    const property = await readFile(path.join(project, 'lawspec_test.go'), 'utf8');
    assert.match(property, /allPayloads/);
    assert.match(property, /lsRapidCheck/);
    const args = ['test', './...', '-count=1', '-v', '-rapid.seed=424242', '-rapid.nofailfile'];
    const run = (extra = []) => spawnSync('go', [...args, ...extra], {cwd: directory, env,
      encoding: 'utf8', maxBuffer: 16 * 1024 * 1024, timeout: 60000});
    const result = run();
    const log = (result.stdout ?? '') + (result.stderr ?? '');
    await writeFile(path.join(directory, 'check.log'), log);
    assert.equal(result.error, undefined);
    assert.equal(result.status, 0, log);
    assert.match(log, /PASS/);
    if (bits === 64 && builtins && !compact) {
      const file = path.join(project, 'lawspec_schema.go');
      const content = await readFile(file, 'utf8');
      const operation = 'return lsBool(s.walkPayload(&lawSpecPayloadPlan{name: t.name, arguments: arguments}, checked, predicates))';
      assert.ok(content.includes(operation));
      try {
        await writeFile(file, content.replace(operation, '_ = checked\n\treturn lsBool(true)'));
        const rejected = run(['-run', '^TestLaw0Property$']);
        const rejection = (rejected.stdout ?? '') + (rejected.stderr ?? '');
        await writeFile(path.join(directory, 'mutant.log'), rejection);
        assert.equal(rejected.error, undefined);
        assert.notEqual(rejected.status, 0, 'Rapid must reject accept-all traversal');
        assert.match(rejection, /--- FAIL: TestLaw0Property/);
      } finally {
        await writeFile(file, content);
      }
    }
  }
}
execFileSync(syntaxChecker, [], {input: JSON.stringify(pairs), encoding: 'utf8'});
console.log('Go payload native APIs, generic constructors, Symbols and Rapid properties pass eight configurations; gofmt, compact parity and accept-all mutation checks pass');
