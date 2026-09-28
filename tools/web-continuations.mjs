// Development-only AST checks shared by the generated-source audit and runtime
// formatter. No parser or formatter is shipped in generated projects.
export function continuationRequirements(ts, source) {
  const lines = source.text.split('\n');
  const lineAt = position => source.getLineAndCharacterOfPosition(position).line;
  const indentation = line => lines[line].match(/^ */)[0].length;
  const requirements = [];
  function continuation(owner, child) {
    if (!child) return;
    const original = lineAt(owner.getStart(source));
    const line = lineAt(child.getStart(source));
    // A child sharing a line with punctuation or another expression is not a
    // new continuation; its containing expression supplies the requirement.
    const column = source.getLineAndCharacterOfPosition(child.getStart(source)).character;
    if (line !== original && column === indentation(line))
      requirements.push({line, original, amount: 4, end: lineAt(child.end)});
  }
  function expressionOrigin(node) {
    let origin = node;
    while (origin.parent && (ts.isParenthesizedExpression(origin.parent) ||
        ts.isBinaryExpression(origin.parent))) origin = origin.parent;
    const parent = origin.parent;
    if (parent && (ts.isVariableDeclaration(parent) || ts.isPropertyAssignment(parent) ||
        ts.isReturnStatement(parent) || ts.isIfStatement(parent) ||
        ts.isCallExpression(parent) || ts.isNewExpression(parent) ||
        ts.isArrowFunction(parent))) origin = parent;
    return origin;
  }
  function visit(node) {
    if (ts.isIfStatement(node) || ts.isWhileStatement(node)) continuation(node, node.expression);
    if (ts.isCallExpression(node) || ts.isNewExpression(node)) {
      for (const argument of node.arguments ?? []) continuation(node, argument);
    }
    if (ts.isFunctionLike(node)) {
      for (const parameter of node.parameters) continuation(node, parameter);
    }
    if (ts.isVariableDeclaration(node) || ts.isPropertyAssignment(node))
      continuation(node, node.initializer);
    if (ts.isVariableDeclarationList(node))
      for (const declaration of node.declarations) continuation(node, declaration);
    if (ts.isBinaryExpression(node)) continuation(expressionOrigin(node), node.right);
    if (ts.isConditionalExpression(node)) {
      continuation(node, node.whenTrue);
      continuation(node, node.whenFalse);
    }
    if (ts.isArrowFunction(node) && !ts.isBlock(node.body)) continuation(node, node.body);
    if (ts.isPropertyAccessExpression(node) &&
        lineAt(node.name.getStart(source)) !== lineAt(node.expression.end)) {
      const line = lineAt(node.name.getStart(source));
      requirements.push({line, original: lineAt(node.expression.getStart(source)), amount: 4, end: lineAt(node.end)});
    }
    ts.forEachChild(node, visit);
  }
  visit(source);
  return requirements;
}

export function continuationViolations(ts, source) {
  const lines = source.text.split('\n');
  const indentation = line => lines[line].match(/^ */)[0].length;
  const messages = continuationRequirements(ts, source).flatMap(({line, original, amount}) =>
    indentation(line) < indentation(original) + amount
      ? [`line ${line + 1}: continuation needs at least ${indentation(original) + amount} spaces`]
      : []);
  const lineAt = position => source.getLineAndCharacterOfPosition(position).line;
  const visit = node => {
    if (ts.isBlock(node)) {
      const opening = lineAt(node.getStart(source));
      for (const statement of node.statements) {
        const line = lineAt(statement.getStart(source));
        if (line !== opening && indentation(line) !== indentation(opening) + 2)
          messages.push(`line ${line + 1}: block statement needs ${indentation(opening) + 2} spaces`);
      }
    }
    ts.forEachChild(node, visit);
  };
  visit(source);
  return messages;
}

// Shift complete child expressions so nested blocks keep their relative layout.
// Token verification below makes this fail closed if a multiline literal would
// be affected. This operates only on reviewed runtime source during development.
export function indentContinuations(ts, source) {
  const lines = source.text.split('\n');
  const indentation = line => lines[line].match(/^ */)[0].length;
  const requirements = continuationRequirements(ts, source)
    .sort((a, b) => a.line - b.line || b.end - a.end);
  for (const {line, original, amount, end} of requirements) {
    const delta = indentation(original) + amount - indentation(line);
    if (delta <= 0) continue;
    for (let index = line; index <= end; index++)
      if (lines[index]) lines[index] = ' '.repeat(delta) + lines[index];
  }
  const result = lines.join('\n');
  const tokens = text => {
    const parsed = ts.createSourceFile('runtime.mjs', text, ts.ScriptTarget.ESNext,
      true, ts.ScriptKind.JS);
    if (parsed.parseDiagnostics.length) throw new Error('Invalid runtime JavaScript');
    const values = [];
    const visit = node => {
      const children = node.getChildren(parsed);
      if (!children.length && node.kind !== ts.SyntaxKind.SyntaxList)
        values.push([node.kind, node.getText(parsed)]);
      else for (const child of children) visit(child);
    };
    visit(parsed);
    return JSON.stringify(values);
  };
  if (tokens(result) !== tokens(source.text))
    throw new Error('Continuation indentation changed JavaScript tokens');
  return result;
}
