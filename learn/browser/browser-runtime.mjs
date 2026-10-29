// esbuild-wasm has no filesystem for computed import globs. The compiler's
// optional native secure-network loader is outside these browser exercises.
// Use TypeScript's parser/printer to replace that one loader with a module that
// fails explicitly when requested; all other generated code remains intact.
/** Refuse the optional native network loader when bundling the runtime for a browser; all other generated runtime code is retained. ref:DEC-learn-course-preview */
export function browserRuntime(ts, source)
{
  const ast = ts.createSourceFile(
    'lawspec_runtime.mjs',
    source,
    ts.ScriptTarget.ES2022,
    true,
    ts.ScriptKind.JS,
  );
  const result = ts.transform(ast, [
    context =>
    {
      const visit = node =>
      {
        if (
          ts.isCallExpression(node) &&
          node.expression.kind === ts.SyntaxKind.ImportKeyword &&
          node.arguments.length === 1
        )
        {
          const arg = node.arguments[0];
          if (
            ts.isBinaryExpression(arg) &&
            ts.isStringLiteral(arg.left) &&
            arg.left.text === './lawspec_network'
          )
          {
            return ts.factory.updateCallExpression(
              node,
              node.expression,
              node.typeArguments,
              [
                ts.factory.createStringLiteral(
                  'browser:unsupported-secure-network',
                ),
              ],
            );
          }
        }
        return ts.visitEachChild(node, visit, context);
      };
      return root => ts.visitNode(root, visit);
    },
  ]);
  try
  {
    return ts.createPrinter().printFile(result.transformed[0]);
  }
  finally
  {
    result.dispose();
  }
}
