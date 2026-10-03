// Syntax highlighting for the documentation: highlight.js, vendored at the
// version pinned in docs/vendor.lock.json, with a LawSpec grammar whose words
// match the VS Code grammar in editors/vscode.
import hljs from "./vendor/highlight/core.js";
import bash from "./vendor/highlight/languages/bash.min.js";
import go from "./vendor/highlight/languages/go.min.js";
import haskell from "./vendor/highlight/languages/haskell.min.js";
import java from "./vendor/highlight/languages/java.min.js";
import javascript from "./vendor/highlight/languages/javascript.min.js";
import json from "./vendor/highlight/languages/json.min.js";
import kotlin from "./vendor/highlight/languages/kotlin.min.js";
import plaintext from "./vendor/highlight/languages/plaintext.min.js";
import python from "./vendor/highlight/languages/python.min.js";
import rust from "./vendor/highlight/languages/rust.min.js";
import typescript from "./vendor/highlight/languages/typescript.min.js";

function lawspec(hljs) {
  return {
    name: "LawSpec",
    aliases: ["lawspec"],
    keywords: {
      keyword:
        "unit import as law requires is end definition description rationale " +
        "example expect implies and references are where refinement type match " +
        "with wrapper workflow",
      literal: "true false null undefined unitValue",
      built_in: "Eq Integer Ordered Bounded",
      type:
        "Int8 Int16 Int32 Int64 UInt8 UInt16 UInt32 UInt64 IntSize UIntSize " +
        "UIntPtr BigInt BigUInt Rational Decimal Float32 Float64 Complex64 " +
        "Complex128 Bool Char CodePoint CodeUnit16 Text CodePointText Utf16Text " +
        "Bytes Symbol Unit Null Undefined List Maybe Either Nullable Optional " +
        "Natural Type",
    },
    contains: [
      hljs.COMMENT("--", "$"),
      { scope: "keyword", begin: /`for all`/ },
      { scope: "title.function", begin: /`/, end: /`/ },
      hljs.QUOTE_STRING_MODE,
      { scope: "built_in", begin: /\bprelude\.[A-Za-z_][A-Za-z0-9_]*/ },
      { scope: "number", begin: /\b\d+(min|ms|us|s|h|d)\b|\b\d+(\.\d+)?([eE][-+]?\d+)?\b/, relevance: 0 },
      { scope: "operator", begin: /::|->|==|!=|<=|>=|&&|\|\|/, relevance: 0 },
    ],
  };
}

for (const [name, language] of Object.entries({
  bash, go, haskell, java, javascript, json, kotlin, plaintext, python, rust, typescript, lawspec,
})) hljs.registerLanguage(name, language);
hljs.registerAliases(["sh", "shell", "console"], { languageName: "bash" });
hljs.registerAliases(["text"], { languageName: "plaintext" });
hljs.registerAliases(["mjs"], { languageName: "javascript" });

// The language for a generated file, by extension.
export function languageOf(path) {
  const extension = path.slice(path.lastIndexOf(".") + 1);
  return { java: "java", py: "python", mjs: "javascript", js: "javascript", ts: "typescript",
    go: "go", hs: "haskell", kt: "kotlin", kts: "kotlin", rs: "rust", json: "json",
    lawspec: "lawspec", sh: "bash" }[extension] ?? "plaintext";
}

// Highlighted HTML for code, escaped when the language is unknown.
export function highlight(code, language) {
  return hljs.highlight(code, { language: hljs.getLanguage(language) ? language : "plaintext", ignoreIllegals: true }).value;
}

// Every fenced code block on the page.
export function highlightPage(root = document) {
  for (const code of root.querySelectorAll('pre > code[class*="language-"]')) {
    const language = [...code.classList].find((c) => c.startsWith("language-"))?.slice(9);
    if (!language || !hljs.getLanguage(language)) continue;
    code.innerHTML = highlight(code.textContent, language);
    code.classList.add("hljs");
  }
}
