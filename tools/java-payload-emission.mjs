import assert from 'node:assert/strict';
import {execFileSync, spawnSync} from 'node:child_process';
import {mkdir, readFile, readdir, writeFile} from 'node:fs/promises';
import path from 'node:path';
import {templates} from '../npm/templates.mjs';
const root = path.resolve(import.meta.dirname, '..');
const fixture = process.env.LAWSPEC_PAYLOAD_FIXTURE;
const formatter = process.env.LAWSPEC_GOOGLE_JAVA_FORMAT;
assert.ok(fixture && formatter, 'Set LAWSPEC_PAYLOAD_FIXTURE and LAWSPEC_GOOGLE_JAVA_FORMAT');
const cache = new Map();
const check = `
import static org.junit.jupiter.api.Assertions.*;
import java.util.HashMap;
import java.util.List;
import lawspec.data.Tree;
import lawspec.data.Pack;
import lawspec.data.GenericPack;
import lawspec.definitions.Payload;
import lawspec.runtime.LawSpecRuntime;
import org.junit.jupiter.api.Test;
public class GeneratedPayloadCheckTest {
  @Test void nativeDefinitions() {
    var symbols = new HashMap<String, Object>();
    Tree<Byte> value = new Tree.NodeCase<>(List.of(
      new Tree.LeafCase<>((byte) 2, (byte) -128), new Tree.LeafCase<>((byte) 3, (byte) 0)));
    assertTrue(Payload.above(symbols, value, (byte) 1));
    assertFalse(Payload.above(symbols, value, (byte) 2));
    assertTrue(Payload.positive(symbols, List.of()));
    assertTrue(Payload.positive(symbols, List.of((byte) 1, (byte) 2)));
    assertFalse(Payload.positive(symbols, List.of((byte) 1, (byte) 0)));
    assertNotNull(Payload.identity(symbols, new Pack.PackCase(value)));
    var error = assertThrows(IllegalArgumentException.class, () -> Payload.identity(symbols,
      new Pack.PackCase(new Tree.LeafCase<>((byte) 0, (byte) 0))));
    assertTrue(error.getMessage().contains("field refinement"));
    assertNotNull(Payload.genericIdentity(symbols, new GenericPack.GenericPackCase<>(value)));
    assertTrue(Payload.shared(symbols, List.of(LawSpecRuntime.symbol("shared", "description", symbols))));
    assertFalse(Payload.shared(symbols, List.of(LawSpecRuntime.symbol("different", "description", symbols))));
  }
}
`;
async function files(dir) {
  const result = [];
  for (const entry of await readdir(dir, {withFileTypes: true})) {
    const file = path.join(dir, entry.name);
    if (entry.isDirectory()) result.push(...await files(file));
    else if (entry.name.endsWith('.java') && entry.name !== 'GeneratedPayloadCheckTest.java') result.push(file);
  }
  return result;
}
for (const bits of [32, 64]) for (const builtins of [false, true]) {
  const readable = new Map();
  for (const compact of [false, true]) {
    const directory = path.join(root, `.artifacts/java-payload-emission/${bits}-${compact}-${builtins}`);
    execFileSync(fixture, [String(bits), compact ? 'True' : 'False', directory, 'java',
      ...(builtins ? ['builtins'] : [])]);
    const generated = await files(path.join(directory, 'src'));
    const entries = [];
    const pending = [];
    for (const file of generated) {
      const content = await readFile(file, 'utf8');
      const copy = path.join(directory, 'formatting', path.relative(directory, file));
      if (!cache.has(content)) {
        await mkdir(path.dirname(copy), {recursive: true});
        await writeFile(copy, content);
        pending.push(copy);
      }
      entries.push({file, content, copy});
    }
    if (pending.length) execFileSync('java', ['-jar', formatter, '--replace', ...pending]);
    for (const {file, content, copy} of entries) {
      if (!cache.has(content)) cache.set(content, await readFile(copy, 'utf8'));
      const formatted = cache.get(content);
      const relative = path.relative(directory, file);
      if (!compact) {
        assert.equal(content, formatted, file);
        readable.set(relative, formatted);
      } else assert.equal(formatted, readable.get(relative), `Compact parity: ${file}`);
    }
    for (const [name, content] of Object.entries(templates('java'))) {
      const destination = path.join(directory, name);
      await mkdir(path.dirname(destination), {recursive: true});
      await writeFile(destination, content);
    }
    if (!builtins) await writeFile(path.join(directory, 'src/test/java/GeneratedPayloadCheckTest.java'), check);
    const property = await readFile(path.join(directory, 'src/test/java/PayloadLawSpecTest.java'), 'utf8');
    assert.match(property, /allPayloads/);
    assert.match(property, /PropertyChecker/);
    const result = spawnSync('mvn', ['-o', '-q', 'test'], {cwd: directory,
      encoding: 'utf8', maxBuffer: 8 * 1024 * 1024, timeout: 60000});
    const log = (result.stdout ?? '') + (result.stderr ?? '');
    await writeFile(path.join(directory, 'check.log'), log);
    assert.equal(result.error, undefined);
    assert.equal(result.status, 0, log);
    const report = await readFile(path.join(directory, 'target/surefire-reports/PayloadLawSpecTest.txt'), 'utf8');
    assert.match(report, /Tests run: [1-9]/);
  }
}
console.log('Java payload definitions, generic constructors, Symbols and properties pass eight width/layout/domain configurations; Google format and compact parity pass');
