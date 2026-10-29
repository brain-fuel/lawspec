// TypeScript performs semantic checking before esbuild strips annotations.
/** Run semantic TypeScript checks against packaged standard libraries before esbuild removes type annotations. ref:DEC-learn-course-preview */
export function checkTypes(ts, files, libraries)
{
  const sources = Object.fromEntries(
    Object.entries({...libraries, ...files}).map(([name, text]) => [
      '/' + name,
      text,
    ]),
  );
  const options = {
    strict: true,
    noEmit: true,
    target: ts.ScriptTarget.ES2022,
    module: ts.ModuleKind.ESNext,
    moduleResolution: ts.ModuleResolutionKind.Bundler,
    allowImportingTsExtensions: true,
    lib: ['lib.es2022.d.ts'],
  };
  const host = {
    getSourceFile: (name, version) =>
      sources[name] === undefined
        ? undefined
        : ts.createSourceFile(name, sources[name], version),
    getDefaultLibFileName: () => '/lib.es2022.d.ts',
    writeFile()
    {},
    getCurrentDirectory: () => '/',
    getDirectories: () => [],
    fileExists: name => Object.hasOwn(sources, name),
    readFile: name => sources[name],
    getCanonicalFileName: name => name,
    useCaseSensitiveFileNames: () => true,
    getNewLine: () => '\n',
  };
  const program = ts.createProgram(
    Object.keys(files).map(name => '/' + name),
    options,
    host,
  );
  return ts.getPreEmitDiagnostics(program).map(row =>
  {
    const pos = row.file?.getLineAndCharacterOfPosition(row.start ?? 0);
    return {
      file: row.file?.fileName,
      line: pos ? pos.line + 1 : undefined,
      column: pos ? pos.character + 1 : undefined,
      severity:
        row.category === ts.DiagnosticCategory.Error ? 'error' : 'warning',
      message: ts.flattenDiagnosticMessageText(row.messageText, '\n'),
    };
  });
}
