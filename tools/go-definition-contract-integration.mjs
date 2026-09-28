import assert from 'node:assert/strict';
import {execFileSync} from 'node:child_process';
import {readFile, writeFile} from 'node:fs/promises';
import path from 'node:path';
const root = path.resolve(import.meta.dirname, '..');
const fixture = process.env.LAWSPEC_GO_CONTRACT_FIXTURE;
assert.ok(fixture, 'Set LAWSPEC_GO_CONTRACT_FIXTURE');
const base = path.join(root, `.artifacts/go-definition-contracts${process.env.LAWSPEC_CONTRACT_SOURCE === '1' ? '-source' : ''}`);
execFileSync(fixture, [base]);
const source = `package fixture
import (
 "fmt"
 "math/big"
 "os"
 "strings"
 "reflect"
 "testing"
)
func reject(t *testing.T, name string, stage string, run func()) {
 t.Helper()
 defer func() {
  err := recover()
  if err == nil { t.Fatalf("accepted %s", name) }
  message := fmt.Sprint(err)
  if !strings.Contains(message, name+":") || !strings.Contains(message, stage) || strings.Contains(message, "division by zero") {
   t.Fatalf("wrong contract failure: %s", message)
  }
 }()
 run()
}
func TestContracts(t *testing.T) {
 symbols := map[string]*LawSpecSymbol{}
 if os.Getenv("CONTRACT_MUTANT") == "1" {
  reject(t, "next", "postcondition", func() { LawSpecDefinitions.Next(symbols, 1) })
  return
 }
 if !reflect.DeepEqual(LawSpecDefinitions.Keep(symbols, []int8{1, 2}), []int8{1, 2}) || !reflect.DeepEqual(LawSpecDefinitions.Stronger(symbols, []int8{11}), []int8{11}) || !reflect.DeepEqual(LawSpecDefinitions.Reuse(symbols, []int8{1}), []int8{1}) { t.Fatal("List contract calls") }
 if len(LawSpecDefinitions.Empty(symbols, 0)) != 0 || !reflect.DeepEqual(LawSpecDefinitions.Singleton(symbols, 1), []int8{1}) { t.Fatal("List postconditions") }
 reject(t, "keep", "precondition", func() { LawSpecDefinitions.Keep(symbols, []int8{1, 0}) })
 reject(t, "stronger", "precondition", func() { LawSpecDefinitions.Stronger(symbols, []int8{1}) })
 reject(t, "reuse", "precondition", func() { LawSpecDefinitions.Reuse(symbols, []int8{0}) })
 if LawSpecDefinitions.Sumreciprocal(symbols, []int8{1, 2}).Cmp(big.NewRat(3, 2)) != 0 || LawSpecDefinitions.Sumreciprocal(symbols, nil).Sign() != 0 { t.Fatal("refined recursion") }
 if LawSpecDefinitions.Sumrows(symbols, [][]int8{{}, {1, 2}, {-2}}).Cmp(big.NewRat(1, 1)) != 0 { t.Fatal("nested refined recursion") }
 if !reflect.DeepEqual(LawSpecDefinitions.Positivetail(symbols, []int8{1, 2}), []int8{2}) || LawSpecDefinitions.Positivefirst(symbols, nil) != 1 { t.Fatal("branch postconditions") }
 reject(t, "sumreciprocal", "precondition", func() { LawSpecDefinitions.Sumreciprocal(symbols, []int8{1, 0}) })
 reject(t, "sumrows", "precondition", func() { LawSpecDefinitions.Sumrows(symbols, [][]int8{{0}}) })
 visited := 0
 visit := func(value LawSpecValue) LawSpecValue { visited++; if visited > 1 { panic("unreachable") }; return lsBool(false) }
 if !lsTruth(lsAllElements(lsList("List Bool", nil), visit)) || visited != 0 { t.Fatal("empty List") }
 if lsTruth(lsAllElements(lsList("List Bool", []LawSpecValue{lsBool(false), lsBool(true)}), visit)) || visited != 1 { t.Fatal("short circuit") }
 if !LawSpecDefinitions.Allpositive(symbols, []int8{}) || !LawSpecDefinitions.Allpositive(symbols, []int8{1, 2}) || LawSpecDefinitions.Allpositive(symbols, []int8{0, -1}) { t.Fatal("List predicates") }
 if !LawSpecDefinitions.Nestedabove(symbols, [][]int8{{}, {3, 4}}) || LawSpecDefinitions.Nestedabove(symbols, [][]int8{{1, 2}}) { t.Fatal("nested List capture") }
 if LawSpecDefinitions.Next(symbols, 127).Cmp(big.NewInt(128)) != 0 { t.Fatal("promotion") }
 if LawSpecDefinitions.Caller(symbols, 1).Cmp(big.NewInt(2)) != 0 { t.Fatal("nested call") }
 if LawSpecDefinitions.Ordered(symbols, 2) != 2 { t.Fatal("ordered predicates") }
 if LawSpecDefinitions.Narrow(symbols, 126) != 127 { t.Fatal("checked narrowing") }
 if LawSpecDefinitions.Reciprocal(symbols, 2).Cmp(big.NewRat(1, 2)) != 0 { t.Fatal("exact division") }
 reject(t, "next", "precondition", func() { LawSpecDefinitions.Next(symbols, 0) })
 reject(t, "caller", "precondition", func() { LawSpecDefinitions.Caller(symbols, 0) })
 reject(t, "reciprocal", "precondition", func() { LawSpecDefinitions.Reciprocal(symbols, 0) })
 reject(t, "ordered", "precondition", func() { LawSpecDefinitions.Ordered(symbols, 0) })
 reject(t, "ordered", "precondition", func() { LawSpecDefinitions.Ordered(symbols, -1) })
 reject(t, "narrow", "precondition", func() { LawSpecDefinitions.Narrow(symbols, 127) })
 reject(t, "next", "precondition", func() { lawSpecEvaluate0(symbols, lsInteger("Int8", "0")) })
}
`;
for (const bits of [32, 64]) for (const mode of ['pretty', 'compact']) {
  const directory = path.join(base, String(bits), mode);
  await writeFile(path.join(directory, 'go.mod'), 'module fixture\n\ngo 1.24.0\n');
  await writeFile(path.join(directory, 'fixture/contracts_test.go'), source);
  const body = path.join(directory, 'fixture/lawspec_definitions.go');
  const original = await readFile(body, 'utf8');
  if (mode === 'pretty') assert.equal(original, execFileSync('gofmt', [body], {encoding: 'utf8'}));
  const run = mutant => execFileSync('go', ['test', '-count=1', './...'], {
    cwd: directory, env: {...process.env, GOTOOLCHAIN: 'local', GOPROXY: 'off',
      GOCACHE: path.join(root, '.artifacts/go-cache'), CONTRACT_MUTANT: mutant ? '1' : ''}, stdio: 'inherit',
  });
  run(false);
  const start = original.indexOf('func lawSpecEvaluate0(');
  const end = original.indexOf('func lawSpecEvaluate1(');
  assert.ok(start >= 0 && end > start);
  const method = original.slice(start, end);
  const changed = method.replace(/result :=[\s\S]*?\n(\s*)checkedResult :=/, 'result := lsInteger("Integer", "0")\n$1checkedResult :=');
  assert.notEqual(changed, method);
  try { await writeFile(body, original.slice(0, start) + changed + original.slice(end)); run(true); }
  finally { await writeFile(body, original); }
  console.log(`go ${bits} ${mode}: native contracts, direct logical checks and corrupted-result rejection passed`);
}
