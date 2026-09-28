// Independently check emitted Python style and readable/compact AST parity.
import assert from 'node:assert/strict';
import {execFileSync} from 'node:child_process';
import {mkdir, readFile, readdir, writeFile} from 'node:fs/promises';
import path from 'node:path';
const root = path.resolve(import.meta.dirname, '..');
const compiler = process.env.LAWSPEC_CORE;
const python = process.env.LAWSPEC_PYTHON ?? 'python3.13';
const checker = process.env.LAWSPEC_PYCODESTYLE;
assert.ok(compiler && checker, 'Set LAWSPEC_CORE and LAWSPEC_PYCODESTYLE (pycodestyle 2.14.0)');
const paths = process.argv.slice(2).length ? process.argv.slice(2) : [
  'test/fixtures/total_definitions.lawspec',
  ...(await readdir(path.join(root, 'examples/specs'))).filter(name => name.endsWith('.lawspec'))
    .sort().map(name => `examples/specs/${name}`),
];
const artifacts = [];
for (const source of paths) {
  const content = await readFile(path.resolve(root, source), 'utf8');
  for (const machineBits of [32, 64]) {
    const generate = minify => {
      const result = JSON.parse(execFileSync(compiler, [], {input: JSON.stringify({
        method: 'planGeneration', target: 'python', machineBits, minify,
        sources: [{path: source, content}],
      }), encoding: 'utf8', maxBuffer: 64 * 1024 * 1024}));
      assert.deepEqual(result.diagnostics, [], source);
      return result.files.filter(file => file.path.endsWith('.py'));
    };
    const readable = generate(false);
    const compact = generate(true);
    assert.deepEqual(readable.map(file => file.path), compact.map(file => file.path));
    for (const [index, file] of readable.entries()) artifacts.push({
      path: `${source}/${machineBits}/${file.path}`,
      content: file.content,
      compact: compact[index].content,
    });
  }
}
const audit = `
import ast
import contextlib
import importlib.util
import io
import json
import sys
spec = importlib.util.spec_from_file_location('pycodestyle', sys.argv[1])
checker = importlib.util.module_from_spec(spec)
spec.loader.exec_module(checker)
assert checker.__version__ == '2.14.0', checker.__version__
style = checker.StyleGuide(config_file=False, max_line_length=79, max_doc_length=72)
failures = []
cache = {}
for artifact in json.load(sys.stdin):
    content = artifact['content']
    if content not in cache:
        output = io.StringIO()
        with contextlib.redirect_stdout(output):
            checker.Checker(filename='generated.py', lines=content.splitlines(True),
                            options=style.options).check_all()
        cache[content] = output.getvalue()
    messages = cache[content]
    try:
        readable = ast.dump(ast.parse(content), include_attributes=False)
        compact = ast.dump(ast.parse(artifact['compact']), include_attributes=False)
        if readable != compact:
            messages += 'Readable and compact ASTs differ\\n'
    except SyntaxError as error:
        messages += str(error) + '\\n'
    if messages:
        failures.append({'path': artifact['path'], 'messages': messages})
print(json.dumps(failures))
`;
const failures = JSON.parse(execFileSync(python, ['-c', audit, checker], {
  input: JSON.stringify(artifacts), encoding: 'utf8', maxBuffer: 64 * 1024 * 1024,
}));
await mkdir(path.join(root, '.artifacts'), {recursive: true});
await writeFile(path.join(root, '.artifacts/python-style-report.json'), JSON.stringify(failures, null, 2) + '\n');
assert.equal(failures.length, 0, `${failures.length} artifacts failed; see .artifacts/python-style-report.json`);
console.log(`${artifacts.length} Python artifacts pass pycodestyle 2.14.0 and readable/compact AST parity at both widths`);
