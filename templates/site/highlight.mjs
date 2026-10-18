// LawSpec uses the editor's shared TextMate grammar and tokenizer. Generated
// native code uses highlight.js. Both runtimes are vendored at locked versions.
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

import {lawSpecHighlighter} from "./lawspec-highlight.mjs";
import {escapeSource} from "./textmate-highlighter.mjs";

for (const [name, language] of Object.entries({
  bash, go, haskell, java, javascript, json, kotlin, plaintext, python, rust, typescript,
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
  if (language === "lawspec") return lawSpecHighlighter?.highlight(code) ?? escapeSource(code);
  return hljs.highlight(code, { language: hljs.getLanguage(language) ? language : "plaintext", ignoreIllegals: true }).value;
}

// Every fenced code block on the page.
export function highlightPage(root = document) {
  for (const code of root.querySelectorAll('pre > code[class*="language-"]')) {
    const language = [...code.classList].find((c) => c.startsWith("language-"))?.slice(9);
    if (!language || language !== "lawspec" && !hljs.getLanguage(language)) continue;
    code.innerHTML = highlight(code.textContent, language);
    code.classList.add("hljs");
  }
}
