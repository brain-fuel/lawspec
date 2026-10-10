import {readFile, readdir, mkdir} from 'node:fs/promises';
import path from 'node:path';
import {templates, commands, setup} from './templates.mjs';
import {safePath, planWrites, applyWrites} from './files.mjs';

async function projectFiles(directory, prefix = '') {
  const files = {};
  for (const entry of await readdir(directory, {withFileTypes: true})) {
    const name = prefix + entry.name;
    const location = new URL(entry.name + (entry.isDirectory() ? '/' : ''), directory);
    if (entry.isDirectory()) Object.assign(files, await projectFiles(location, name + '/'));
    else if (entry.isFile()) files[name] = await readFile(location, 'utf8');
    else throw new Error(`Unsupported bundled example entry: ${name}`);
  }
  return files;
}

export async function exportNativePayments(options, selected) {
  const root = await safePath(process.cwd(), options.output || 'native_payments');
  await mkdir(root, {recursive: true});
  const law = await readFile(new URL('./examples/specs/payments.lawspec', import.meta.url), 'utf8');
  const plans = [];
  const results = [];
  for (const target of selected) {
    const directory = await safePath(root, target);
    await mkdir(directory, {recursive: true});
    const files = {
      ...templates(target, {minify: options.minify === true}),
      ...await projectFiles(new URL(`./examples/native-payments/${target}/`, import.meta.url)),
      'laws/payments.lawspec': law,
    };
    const config = JSON.parse(files['lawspec.json']);
    config.machineBits = options.machineBits ?? 64;
    files['lawspec.json'] = JSON.stringify(config, null, options.minify ? undefined : 2) + '\n';
    const instructions = target === 'gleam' ? setup[target].replace(
      'Prepare dependencies with gleam build, then run gleam test.',
      'Prepare dependencies with node prepare.mjs before generation, then run gleam test.') : setup[target];
    files['README.md'] = `# Native payments: ${target}

This project checks application-owned payment types against the shared LawSpec
model. Money maps to Price, currency variants have application names, and the
archive preserves distinct present and absent payments.

## Run

Install LawSpec and the native dependencies described below, then run:

\`\`\`sh
lawspec check
${target === 'gleam' ? 'node prepare.mjs\n' : ''}lawspec generate
${commands[target]}
\`\`\`

${instructions}

${target === 'gleam' ? 'The preparation command compiles dependencies in a temporary project using\nyour dependency requirements and lock file. It leaves application sources in\nplace, so their imports can be resolved after LawSpec generates the runtime.\n' : ''}

JavaScript and TypeScript projects require \`npm install\` before testing.
The specification includes exact decimal arithmetic and explicit USD/GBP examples.
The native price generator deliberately samples only EUR values between 1.00 and
2.00; examples and deterministic boundaries still check the other cases. Its
framework's mapping operation preserves the native shrinker.

The application types use native exact decimals where available and LawSpec's
framework-independent numeric runtime otherwise. Run generation before compiling
the application so that runtime support is present.

## Change the application

Edit the domain implementation or generator, then run the native tests again.
For example, change the fee from 0.2 to 0.3: the exact-decimal law must fail.
Edit \`lawspec.json\` to change native bindings and rerun \`lawspec generate\`.

All exported project files are user-owned. Re-exporting preserves your edits;
it reports changed bundled versions for review. Compiler-generated files use a
separate ownership manifest and remain protected against accidental overwrites.
`;
    const artifacts = Object.entries(files).map(([path, content]) => ({path, content, ownership: 'user'}));
    const plan = await planWrites(directory, artifacts, {manifest: '.lawspec/example.json'});
    plans.push(plan);
    results.push({target, directory, example: 'payments', files: artifacts.map(({path, ownership}) => ({path, ownership})),
      changes: plan.changes.length, preservedAdapters: plan.preserved, adapterUpdates: plan.adapterUpdates});
  }
  await applyWrites(plans);
  return results;
}
