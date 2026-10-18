// The editor and website interpret the same grammar with the same tokenizer.
// This adapter only maps TextMate scopes to the site's existing theme classes.
export function escapeSource(source) {
  return source.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;").replace(/'/g, "&#39;").replace(/\r/g, "&#13;");
}

function themeClass(scopes) {
  for (const scope of [...scopes].reverse()) {
    if (scope.startsWith("comment.")) return "hljs-comment";
    if (scope.startsWith("constant.character.escape")) return "hljs-char escape_";
    if (scope.startsWith("string.")) return "hljs-string";
    if (scope.startsWith("support.type.class")) return "hljs-built_in";
    if (scope.startsWith("support.type") || scope.startsWith("entity.name.type")) return "hljs-type";
    if (scope.startsWith("entity.name.function")) return "hljs-title function_";
    if (scope.startsWith("entity.name.namespace")) return "hljs-title";
    if (scope.startsWith("support.function")) return "hljs-built_in";
    if (scope.startsWith("constant.numeric")) return "hljs-number";
    if (scope.startsWith("constant.language")) return "hljs-literal";
    if (scope.startsWith("keyword.operator")) return "hljs-operator";
    if (scope.startsWith("keyword.")) return "hljs-keyword";
    if (scope.startsWith("variable.parameter")) return "hljs-params";
  }
  return "";
}

export async function createLawSpecHighlighter(textmate, oniguruma, rawGrammar, wasm) {
  if (rawGrammar.scopeName !== "source.lawspec") throw new Error("Expected the shared LawSpec grammar.");
  await oniguruma.loadWASM(wasm);
  const registry = new textmate.Registry({
    onigLib: Promise.resolve({
      createOnigScanner: patterns => new oniguruma.OnigScanner(patterns),
      createOnigString: source => new oniguruma.OnigString(source),
    }),
    loadGrammar: async name => name === "source.lawspec" ? rawGrammar : null,
  });
  const grammar = await registry.loadGrammar("source.lawspec");
  if (!grammar) throw new Error("The shared LawSpec grammar did not load.");
  function tokenize(source) {
    let state = textmate.INITIAL;
    return source.split("\n").map(line => {
      const result = grammar.tokenizeLine(line, state);
      state = result.ruleStack;
      return { line, tokens: result.tokens };
    });
  }
  return {
    tokenize,
    highlight: source => tokenize(source).map(({ line, tokens }) => tokens.map(token => {
      const value = escapeSource(line.slice(token.startIndex, token.endIndex));
      const scope = themeClass(token.scopes);
      return value && scope ? `<span class="${scope}">${value}</span>` : value;
    }).join("")).join("\n"),
    dispose: () => registry.dispose(),
  };
}
