import assert from 'node:assert/strict';
import {execFileSync} from 'node:child_process';
import {mkdir, readdir, readFile, writeFile} from 'node:fs/promises';
import path from 'node:path';
const root = path.resolve(import.meta.dirname, '..');
const fixture = process.env.LAWSPEC_JVM_CONTRACT_FIXTURE;
const formatter = process.env.LAWSPEC_GOOGLE_JAVA_FORMAT;
assert.ok(fixture && formatter, 'Set LAWSPEC_JVM_CONTRACT_FIXTURE and LAWSPEC_GOOGLE_JAVA_FORMAT');
const base = path.join(root, `.artifacts/jvm-definition-contracts${process.env.LAWSPEC_CONTRACT_SOURCE === '1' ? '-source' : ''}`);
execFileSync(fixture, [base]);
async function files(directory) {
  return (await Promise.all((await readdir(directory, {withFileTypes: true})).map(entry => {
    const full = path.join(directory, entry.name);
    return entry.isDirectory() ? files(full) : [full];
  }))).flat();
}
const check = `import java.math.BigInteger;
import java.util.HashMap;
import java.util.Map;
import java.lang.reflect.InvocationTargetException;
import java.lang.reflect.Modifier;
import lawspec.runtime.LawSpecRuntime;
public class ContractCheck {
  static final Map<String,Object> symbols = new HashMap<>();
  static Object call(String name, Object value) throws Exception {
    var clazz = Class.forName("lawspec.definitions.Fixture");
    var method = java.util.Arrays.stream(clazz.getMethods()).filter(m -> m.getName().equals(name) && m.getParameterCount() == 2).findFirst().orElseThrow();
    try {
      return method.invoke(Modifier.isStatic(method.getModifiers()) ? null : clazz.getField("INSTANCE").get(null), symbols, value);
    } catch (InvocationTargetException e) { throw (RuntimeException)e.getCause(); }
  }
  static void reject(String name, Object input, String stage) throws Exception {
    try { call(name, input); throw new AssertionError("accepted " + name); }
    catch (IllegalArgumentException e) {
      if (!e.getMessage().contains(name + ":") || !e.getMessage().contains(stage)) throw e;
      if (e.getMessage().contains("division by zero")) throw new AssertionError("precondition evaluated too late", e);
    }
  }
  public static void main(String[] args) throws Exception {
    if (args.length > 1) { reject("next", (byte)1, "postcondition"); return; }
    int bits = Integer.parseInt(args[0]);
    if (!LawSpecRuntime.equal(LawSpecRuntime.fromNative("Rational", call("sumreciprocal", java.util.List.of((byte)1, (byte)2)), bits), LawSpecRuntime.rational("3", "2"))) throw new AssertionError("refined recursion");
    if (!LawSpecRuntime.equal(LawSpecRuntime.fromNative("Rational", call("sumreciprocal", java.util.List.of()), bits), LawSpecRuntime.rational("0", "1"))) throw new AssertionError("empty recursion");
    if (!LawSpecRuntime.equal(LawSpecRuntime.fromNative("Rational", call("sumrows", java.util.List.of(java.util.List.of(), java.util.List.of((byte)1, (byte)2), java.util.List.of((byte)-2))), bits), LawSpecRuntime.rational("1", "1"))) throw new AssertionError("nested refined recursion");
    if (!call("positivetail", java.util.List.of((byte)1, (byte)2)).equals(java.util.List.of((byte)2)) || !call("positivefirst", java.util.List.of()).equals((byte)1)) throw new AssertionError("branch postconditions");
    reject("sumreciprocal", java.util.List.of((byte)1, (byte)0), "precondition");
    reject("sumrows", java.util.List.of(java.util.List.of((byte)0)), "precondition");
    if (!call("keep", java.util.List.of((byte)1, (byte)2)).equals(java.util.List.of((byte)1, (byte)2))
        || !call("stronger", java.util.List.of((byte)11)).equals(java.util.List.of((byte)11))
        || !call("reuse", java.util.List.of((byte)1)).equals(java.util.List.of((byte)1))) throw new AssertionError("List contract calls");
    if (!call("empty", (byte)0).equals(java.util.List.of()) || !call("singleton", (byte)1).equals(java.util.List.of((byte)1))) throw new AssertionError("List postconditions");
    reject("keep", java.util.List.of((byte)1, (byte)0), "precondition");
    reject("stronger", java.util.List.of((byte)1), "precondition");
    reject("reuse", java.util.List.of((byte)0), "precondition");
    int[] visits = {0};
    java.util.function.Function<LawSpecRuntime.Value, LawSpecRuntime.Value> visit = value -> {
      if (++visits[0] > 1) throw new AssertionError("unreachable");
      return LawSpecRuntime.bool(false);
    };
    if (!LawSpecRuntime.truth(LawSpecRuntime.allElements(LawSpecRuntime.list("List Bool", java.util.List.of()), visit)) || visits[0] != 0) throw new AssertionError("empty List");
    if (LawSpecRuntime.truth(LawSpecRuntime.allElements(LawSpecRuntime.list("List Bool", java.util.List.of(LawSpecRuntime.bool(false), LawSpecRuntime.bool(true))), visit)) || visits[0] != 1) throw new AssertionError("short circuit");
    if (!call("allpositive", java.util.List.of()).equals(true)
        || !call("allpositive", java.util.List.of((byte)1, (byte)2)).equals(true)
        || !call("allpositive", java.util.List.of((byte)0, (byte)-1)).equals(false)) throw new AssertionError("List predicates");
    if (!call("nestedabove", java.util.List.of(java.util.List.of(), java.util.List.of((byte)3, (byte)4))).equals(true)
        || !call("nestedabove", java.util.List.of(java.util.List.of((byte)1, (byte)2))).equals(false)) throw new AssertionError("nested List capture");
    if (!call("next", (byte)127).equals(BigInteger.valueOf(128))) throw new AssertionError("promotion");
    if (!call("caller", (byte)1).equals(BigInteger.TWO)) throw new AssertionError("nested call");
    if (!call("ordered", (byte)2).equals((byte)2)) throw new AssertionError("ordered predicates");
    if (!call("narrow", (byte)126).equals((byte)127)) throw new AssertionError("checked narrowing");
    if (!LawSpecRuntime.equal(LawSpecRuntime.fromNative("Rational", call("reciprocal", (byte)2), bits), LawSpecRuntime.rational("1", "2"))) throw new AssertionError("exact division");
    reject("next", (byte)0, "precondition");
    reject("caller", (byte)0, "precondition");
    reject("reciprocal", (byte)0, "precondition");
    reject("ordered", (byte)0, "precondition");
    reject("ordered", (byte)-1, "precondition");
    reject("narrow", (byte)127, "precondition");
    try {
      lawspec.runtime.LawSpecDefinitionBodies.evaluate0(symbols, LawSpecRuntime.integer("Int8", "0"));
      throw new AssertionError("unchecked logical entry point");
    } catch (IllegalArgumentException e) {
      if (!e.getMessage().contains("precondition")) throw e;
    }
    System.out.println("native contracts passed " + bits);
  }
}
`;
for (const target of ['java', 'kotlin']) for (const bits of [32, 64]) for (const mode of ['pretty', 'compact']) {
  const directory = path.join(base, target, String(bits), mode);
  const sources = await files(path.join(directory, 'src'));
  const java = sources.filter(file => file.endsWith('.java'));
  const kotlin = sources.filter(file => file.endsWith('.kt'));
  const body = java.find(file => file.endsWith('/LawSpecDefinitionBodies.java'));
  const original = await readFile(body, 'utf8');
  if (mode === 'pretty') assert.equal(original, execFileSync('java', ['-jar', formatter, body], {encoding: 'utf8'}));
  const classes = path.join(directory, 'classes');
  await mkdir(classes, {recursive: true});
  const runner = path.join(directory, 'ContractCheck.java');
  await writeFile(runner, check);
  const compileJava = () => execFileSync('javac', ['--release', '25', '-d', classes, ...java, runner], {stdio: 'inherit'});
  compileJava();
  const jar = path.join(directory, 'native.jar');
  if (kotlin.length) execFileSync('kotlinc', ['-jvm-target', '25', '-classpath', classes, ...kotlin, '-d', jar], {stdio: 'inherit'});
  const execute = extra => execFileSync(target === 'java' ? 'java' : 'kotlin',
    ['-classpath', target === 'java' ? classes : `${classes}:${jar}`, 'ContractCheck', String(bits), ...extra], {stdio: 'inherit'});
  execute([]);
  if (kotlin.length) execFileSync('kotlin', ['-classpath', `${classes}:${jar}`, 'lawspec.runtime.ListPredicateFixtureKt'], {stdio: 'inherit'});
  const mutated = original.replace(/var result =[\s\S]*?;\s*var checkedResult/, 'var result = LawSpecRuntime.integer("Integer", "0");\nvar checkedResult');
  assert.notEqual(mutated, original);
  try {
    await writeFile(body, mutated);
    compileJava();
    execute(['mutant']);
  } finally { await writeFile(body, original); }
  console.log(`${target} ${bits} ${mode}: contracts, checked entry points and corrupted-result rejection passed`);
}
