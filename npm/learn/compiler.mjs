import {
  implementationBinding,
  fsharpAdapter,
  adapterSource,
  harnessModule,
} from './adapters.mjs';
import {harnessHostModules} from './harness-host.mjs';
import {bundle} from './bundle.mjs';
import {runnerEntry, supportSource, nodeTestSource} from './runner.mjs';
import {lawLabel} from './presentation.mjs';
/** Run mandatory definition admission and language checking before packaging authored and generated checks for isolated execution. ref:DEC-learn-course-preview */
export async function compileProject(request, services)
{
  const {
    language,
    files,
    mode = 'all',
    seed = 424242,
    path = '',
    replayTest = null,
  } = request;
  if (!Number.isInteger(seed) || seed < -2147483648 || seed > 2147483647)
  {
    throw new Error('Seed must be a 32-bit integer');
  }
  if (!['all', 'examples', 'sample'].includes(mode))
  {
    throw new Error('Unsupported execution mode');
  }
  const diagnostics = [],
    generated = [];
  let modules = {},
    lawResult = null;
  // Admission is mandatory even for the separate authored-example mode.
  const sources = Object.entries(files)
    .filter(([path]) => path.endsWith('.lawspec'))
    .map(([path, content]) => ({path, content}));
  if (!sources.some(source => source.path === 'Tests.lawspec'))
  {
    throw new Error('Missing Tests.lawspec');
  }
  const compiler = await services.lawspec();
  lawResult = await compiler.check({
    languageProfile: '1.0-rc.2',
    verification: {layers: []},
    sources,
  });
  diagnostics.push(
    ...(lawResult.diagnostics ?? []).map(row => ({
      ...row,
      severity: row.severity ?? 'error',
    })),
  );
  if (diagnostics.some(row => row.severity === 'error'))
  {
    return {
      diagnostics,
      definitionValidation: lawResult.verification,
      evidence: lawResult.evidence,
    };
  }
  let binding;
  try
  {
    binding = implementationBinding(
      lawResult,
      sources.map(source => source.path),
    );
  }
  catch (error)
  {
    return {
      diagnostics: [
        {
          severity: 'error',
          code: 'LEARN_UNSUPPORTED_BINDING',
          message: error.message,
        },
      ],
      definitionValidation: lawResult.verification,
      evidence: lawResult.evidence,
    };
  }
  const fn = binding.name;
  let propertyMetadata = {};
  let checks = [];
  generated.push({
    path: 'adapter/binding.json',
    content: JSON.stringify(binding, null, 2) + '\n',
  });
  if (language === 'fsharp')
  {
    const bridge = fsharpAdapter(binding);
    const result = await services.fsharp({
      'Solution.fs': files['Solution.fs'],
      'Adapter.fs': bridge,
    });
    diagnostics.push(...result.diagnostics);
    modules = result.modules;
    generated.push(
      {path: 'adapter/Adapter.fs', content: bridge},
      ...Object.entries(modules).map(([path, content]) => ({
        path: 'fable/' + path,
        content,
      })),
    );
  }
  else if (language === 'javascript' || language === 'typescript')
  {
    const ext = language === 'typescript' ? 'ts' : 'js';
    modules = {[`Solution.${ext}`]: files[`Solution.${ext}`]};
    if (language === 'typescript')
    {
      diagnostics.push(...(await services.typescript(modules)));
    }
  }
  else
  {
    return {
      diagnostics: [
        {severity: 'error', message: 'Unsupported browser language'},
      ],
    };
  }
  if (diagnostics.some(row => row.severity === 'error'))
  {
    return {diagnostics, definitionValidation: lawResult.verification};
  }
  {
    const plan = await compiler.planGeneration({
      languageProfile: '1.0-rc.2',
      target: 'javascript',
      verification: {layers: ['property']},
      sources,
    });
    diagnostics.push(...(plan.diagnostics ?? []));
    if (plan.diagnostics?.length)
    {
      return {diagnostics, definitionValidation: lawResult.verification};
    }
    for (const file of plan.files ?? [])
    {
      if (file.ownership !== 'user')
      {
        modules[file.path] = file.content;
        generated.push(file);
      }
    }
    lawResult = plan;
    checks = (plan.tests ?? []).map(test =>
    {
      const law = plan.laws.find(row => row.id === test.law);
      return {
        name: test.name,
        label: law ? lawLabel(law.name) : test.label,
        quantified: Boolean(law?.inputs.length),
      };
    });
    propertyMetadata = Object.fromEntries(
      (plan.laws ?? []).map(law => [
        law.owner + '::' + law.name + ' property',
        {
          inputNames: law.inputs.map(input => input.name),
          inputValues: Boolean(law.harness?.strategies?.length),
        },
      ]),
    );
    // Every generated check calls the implementation through this checked
    // bridge. Int32 values map exactly; lists cross explicitly.
    const modulePath = harnessModule(plan, binding);
    const depth = modulePath.split('/').length - 1;
    modules[modulePath] =
      `export {${fn}} from '${'../'.repeat(depth)}lesson-adapter.js';`;
    generated.push({
      path: 'adapter/' + modulePath,
      content: modules[modulePath],
    });
  }
  if (modules['src/lawspec_runtime.mjs'])
  {
    modules['src/lawspec_runtime.mjs'] = services.browserRuntime(
      modules['src/lawspec_runtime.mjs'],
    );
  }
  modules['lesson-adapter.js'] = adapterSource(binding, language);
  generated.push({
    path: 'adapter/lesson-adapter.js',
    content: modules['lesson-adapter.js'],
  });
  modules['run-support.mjs'] = supportSource;
  modules['fast-check.mjs'] =
    `export * from 'fast-check-original';export {default,assert} from './run-support.mjs';`;
  modules['node-test.mjs'] = nodeTestSource;
  modules['assert.mjs'] = await services.readAsset('assert.mjs');
  Object.assign(modules, harnessHostModules());
  const testFiles = Object.keys(modules).filter(
    name => name.startsWith('test/') && name.endsWith('.mjs'),
  );
  if (path && !replayTest)
  {
    throw new Error('A replay path must identify the failing LawSpec test');
  }
  modules['entry.mjs'] = runnerEntry({
    testFiles,
    seed,
    path,
    replayTest,
    mode,
    propertyMetadata,
  });
  const code = await bundle(
    services.esbuild,
    modules,
    'entry.mjs',
    services.readAsset,
  );
  return {
    code,
    diagnostics,
    binding,
    checks,
    generated: generated.map(({path, content}) => ({path, content})),
    definitionValidation: lawResult.verification,
    evidence: lawResult.evidence ?? [],
    execution:
      language === 'fsharp'
        ? 'F# → Fable → JavaScript; LawSpec JS harness + fast-check'
        : 'JavaScript execution; LawSpec JS harness + fast-check',
  };
}
