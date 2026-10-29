// Fable's own manager and printer perform type checking and emission.
/** Check the exercise and typed bridge with Fable, then emit JavaScript through its PrintTargetAst API. ref:DEC-learn-course-preview */
export async function createFsharp(fable, assemblies)
{
  const manager = fable.init();
  const names = Object.keys(assemblies).map(name => name.replace(/\.dll$/, ''));
  const checker = manager.CreateChecker(
    names,
    name =>
    {
      const bytes = assemblies[name.endsWith('.dll') ? name : name + '.dll'];
      if (!bytes)
      {
        throw new Error('Missing F# assembly: ' + name);
      }
      return bytes;
    },
    ['--langversion:preview'],
  );
  return async files =>
  {
    const names = Object.keys(files),
      diagnostics = [];
    const checked = manager.ParseAndCheckProject(
      checker,
      'Lesson.fsproj',
      names,
      Object.values(files),
    );
    const convert = error => ({
      file: error.FileName,
      line: error.StartLine,
      column: error.StartColumn + 1,
      severity: error.IsWarning ? 'warning' : 'error',
      message: error.Message,
    });
    diagnostics.push(...manager.GetErrors(checked).map(convert));
    const modules = {};
    if (diagnostics.some(row => row.severity === 'error'))
    {
      return {diagnostics, modules};
    }
    for (const name of names)
    {
      const ast = manager.CompileToTargetAst(
        'fable-library',
        checked,
        name,
        false,
        'javascript',
      );
      diagnostics.push(...ast.FableErrors.map(convert));
      let code = '';
      const writer = {
        Dispose()
        {},
        AddSourceMapping()
        {},
        MakeImportPath: path =>
          path.endsWith('.fs') ? './' + path.slice(0, -3) + '.js' : path,
        Write: text => context =>
        {
          code += text;
          context.onSuccess();
        },
      };
      await new Promise((resolve, reject) =>
        manager.PrintTargetAst(
          ast,
          writer,
        )({
          onSuccess: resolve,
          onError: reject,
          onCancel: reject,
          cancelToken: {isCancelled: false},
          trampoline: {incrementAndCheck: () => false, hijack: fn => fn()},
        }),
      );
      modules[name.replace(/\.fs$/, '.js')] = code;
    }
    return {diagnostics, modules};
  };
}
