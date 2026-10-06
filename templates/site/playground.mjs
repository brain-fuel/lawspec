// <lawspec-playground>: the documentation's workbench. Every LawSpec example
// on the site is one, and every place a lesson shows code can be one.
//
// For the selected language it shows the files LawSpec works with:
//
//   the specification           editable
//   your implementation         editable: the adapters LawSpec never overwrites
//   the generated tests         read-only
//   generated support code      read-only
//
// Check compiles the specification and lists how each law is established.
// Run generates the tests from the current specification and runs them
// against the current implementation, exactly as edited, in a sandbox: an
// opaque-origin frame with no access to this page, its storage or the
// network. Tests run in the browser for JavaScript and TypeScript (which the
// page first transpiles with the TypeScript compiler); the other languages
// show the command that runs them in your project.
//
// Workbenches with the same data-key share one model, so a lesson can show
// the specification in one place and the implementation in another, and Run
// in either uses both.
//
// Attributes, written by lawspec-dev docs:
//   data-source   the specification             data-path  its file name
//   data-extra    [{path, content}] other units compiled with it (imports)
//   data-implementations  {"java": {"src/…": "…"}, …} working implementations
//   data-target   the language shown first
//   data-view     "implementation" to open on the implementation
//   data-key      the shared model's name

import { highlight, highlightPage, languageOf } from "./highlight.mjs";

const targets = [["java", "Java"], ["python", "Python"], ["javascript", "JavaScript"], ["typescript", "TypeScript"],
  ["go", "Go"], ["haskell", "Haskell"], ["kotlin", "Kotlin"], ["rust", "Rust"]];
const runnable = new Set(["javascript", "typescript"]);
const badges = { javascript: "JS", typescript: "TS" };
const testCommands = /*@ test-commands @*/;
const statusLabels = { "proved": "proved", "exhaustively-checked": "exhaustively checked",
  "property-tested": "property tested", "runtime-checked": "runtime checked", "default-handler": "default handler", "assumed": "assumed" };
const assets = new URL("./", import.meta.url);
let compiler;

// The TypeScript compiler, loaded once, the first time TypeScript runs. It
// only transpiles: the sandbox runs the JavaScript it produces.
let typescript;
function loadTypeScript() {
  typescript ??= new Promise((resolve, reject) => {
    const script = element("script", { src: new URL("vendor/typescript/typescript.js", assets).href });
    script.addEventListener("load", () => resolve(globalThis.ts));
    script.addEventListener("error", () => reject(new Error("Cannot load the TypeScript compiler.")));
    document.head.append(script);
  });
  return typescript;
}

// TypeScript modules as the JavaScript modules they compile to. Generated
// imports already name the .js files.
async function transpile(modules) {
  const ts = await loadTypeScript();
  const out = {};
  const problems = [];
  for (const [path, source] of Object.entries(modules)) {
    if (!path.endsWith(".ts")) { out[path] = source; continue; }
    const result = ts.transpileModule(source, { fileName: path, reportDiagnostics: true,
      compilerOptions: { module: ts.ModuleKind.ESNext, target: ts.ScriptTarget.ES2022 } });
    for (const d of result.diagnostics ?? []) {
      const at = d.file && d.start !== undefined ? d.file.getLineAndCharacterOfPosition(d.start) : null;
      problems.push(`${path}${at ? `:${at.line + 1}:${at.character + 1}` : ""}: ${ts.flattenDiagnosticMessageText(d.messageText, "\n")}`);
    }
    out[path.replace(/\.ts$/, ".js")] = result.outputText;
  }
  if (problems.length) throw new Error(problems.join("\n"));
  return out;
}

function loadCompiler() {
  compiler ??= import(new URL("lawspec-core.mjs", assets)).then(({ createCompiler }) =>
    createCompiler(new URL("core.wasm", assets)));
  return compiler;
}

function element(tag, attributes = {}, children = []) {
  const node = document.createElement(tag);
  for (const [key, value] of Object.entries(attributes)) {
    if (key === "text") node.textContent = value;
    else if (value !== false && value !== undefined) node.setAttribute(key, value === true ? "" : value);
  }
  node.append(...children);
  return node;
}

function button(label, title, action, extra = {}) {
  const b = element("button", { type: "button", title, ...extra, text: label });
  b.addEventListener("click", action);
  return b;
}

// The shared state of one example: its specification, the implementation
// files as edited for each language, and the latest generated code.
class Model extends EventTarget {
  constructor(element) {
    super();
    this.path = element.dataset.path ?? "spec.lawspec";
    this.originalSpec = element.dataset.source ?? "";
    this.spec = this.originalSpec;
    this.extra = JSON.parse(element.dataset.extra ?? "[]");
    this.provided = JSON.parse(element.dataset.implementations ?? "{}");
    this.edits = {};
    this.generated = {};
  }

  sources() {
    return [...this.extra, { path: this.path, content: this.spec }];
  }

  setSpec(text, origin) {
    this.spec = text;
    this.generated = {};
    this.dispatchEvent(new CustomEvent("change", { detail: { origin } }));
  }

  // An implementation file as the reader last left it, or the working one,
  // or the stub LawSpec generates.
  implementation(target, file) {
    return this.edits[target]?.[file.path] ?? this.provided[target]?.[file.path] ?? file.content;
  }

  setImplementation(target, path, text, origin) {
    (this.edits[target] ??= {})[path] = text;
    this.dispatchEvent(new CustomEvent("change", { detail: { origin } }));
  }

  reset() {
    this.spec = this.originalSpec;
    this.edits = {};
    this.generated = {};
    this.dispatchEvent(new CustomEvent("change", { detail: { reset: true } }));
  }

  // The generated files for a target, compiled from the current specification.
  async generate(target) {
    const spec = this.spec;
    if (this.generated[target]?.spec === spec) return this.generated[target].result;
    const result = await (await loadCompiler()).planGeneration({ sources: this.sources(), target });
    this.generated[target] = { spec, result };
    return result;
  }

  // Before anything is compiled: the implementation files known for a language.
  knownImplementation(target) {
    return Object.keys(this.provided[target] ?? {}).map((path) => ({ path, ownership: "user", placement: "source", content: "" }));
  }
}

const models = new Map();
function modelFor(node) {
  const key = node.dataset.key ?? node.dataset.path ?? String(models.size);
  if (!models.has(key)) models.set(key, new Model(node));
  return models.get(key);
}

// An editable, highlighted pane: a transparent textarea over its highlighted
// copy, sized to its content.
function editablePane(value, language, label, onInput) {
  const area = element("textarea", { class: "source", spellcheck: "false", wrap: "off", "aria-label": label });
  area.value = value;
  const shadow = element("code", { class: `hljs language-${language}` });
  const backdrop = element("pre", { class: "backdrop", "aria-hidden": "true" }, [shadow]);
  const paint = () => {
    shadow.innerHTML = highlight(area.value, language) + "\n";
    area.style.height = "auto";
    area.style.height = `${Math.min(area.scrollHeight + 2, 640)}px`;
  };
  area.addEventListener("input", () => { paint(); onInput(area.value); });
  area.addEventListener("scroll", () => {
    backdrop.scrollTop = area.scrollTop;
    backdrop.scrollLeft = area.scrollLeft;
  });
  requestAnimationFrame(paint);
  return element("div", { class: "editor" }, [backdrop, area]);
}

function readOnlyPane(value, language) {
  const code = element("code", { class: `hljs language-${language}` });
  code.innerHTML = highlight(value, language);
  return element("pre", { class: "readonly" }, [code]);
}

class Playground extends HTMLElement {
  connectedCallback() {
    if (this.ready) return;
    this.ready = true;
    this.model = modelFor(this);
    this.target = this.dataset.target ?? "java";

    // Languages whose tests run here come first, apart from the others.
    const tab = ([id, label]) => {
      const b = button("", runnable.has(id) ? `${label}: tests run in your browser` : `${label}: tests run in your project`,
        () => this.select(id, this.openKind()), { role: "tab" });
      if (badges[id]) b.append(element("span", { class: `badge-${id}`, text: badges[id], "aria-hidden": "true" }), " ");
      b.append(label);
      b.dataset.target = id;
      return b;
    };
    this.tabs = element("div", { class: "tabs", role: "tablist", "aria-label": "Language" }, [
      element("div", { class: "group runs-here" }, [element("span", { class: "group-label", text: "▶ Runs here" }),
        ...targets.filter(([id]) => runnable.has(id)).map(tab)]),
      element("div", { class: "group" }, [element("span", { class: "group-label", text: "Runs in your project" }),
        ...targets.filter(([id]) => !runnable.has(id)).map(tab)]),
    ]);
    this.runButton = button("▶ Run", "", () => this.run(), { class: "primary" });
    this.status = element("span", { class: "status", role: "status" });
    const toolbar = element("div", { class: "toolbar" }, [
      this.runButton,
      button("Check", "Compile the specification and show how each law is established", () => this.check()),
      button("↺", "Restore the example", () => this.model.reset(), { "aria-label": "Restore the example" }),
      button("⎘", "Copy the file shown", () => navigator.clipboard?.writeText(this.currentText ?? ""), { "aria-label": "Copy the file shown" }),
      this.status,
    ]);
    this.fileList = element("nav", { class: "filelist", "aria-label": "Files" });
    this.pane = element("div", { class: "pane" });
    this.output = element("div", { class: "output", hidden: true, "aria-live": "polite" });
    this.replaceChildren(this.tabs, toolbar, element("div", { class: "workspace" }, [this.fileList, this.pane]), this.output);

    this.model.addEventListener("change", ({ detail }) => {
      if (detail.origin === this) return;
      if (detail.reset) this.output.hidden = true;
      this.select(this.target, this.openKind());
    });
    this.select(this.target, this.dataset.view === "implementation" ? "implementation" : "spec");
  }

  // What the workbench has open: the specification, the implementation, or a
  // generated file by path.
  openKind() {
    if (!this.selected) return "spec";
    return this.selected.kind === "spec" || this.selected.kind === "implementation" ? this.selected.kind : this.selected.file.path;
  }

  select(target, open) {
    this.target = target;
    for (const b of this.tabs.querySelectorAll("button")) b.setAttribute("aria-selected", String(b.dataset.target === target));
    const name = targets.find(([id]) => id === target)[1];
    this.runButton.disabled = !runnable.has(target);
    this.runButton.title = runnable.has(target)
      ? "Generate the tests from this specification and run them against this implementation, in a sandbox"
      : `${name} tests run in your project${testCommands[target] ? `: ${testCommands[target]}` : ""}. JavaScript and TypeScript run in the browser.`;
    const generated = this.model.generated[target];
    const current = generated?.spec === this.model.spec && !generated.result.diagnostics.length ? generated.result.files : null;
    this.renderFiles(current ?? this.model.knownImplementation(target), !current, open);
  }

  renderFiles(files, partial, open) {
    this.renderedSpec = partial ? null : this.model.spec;
    const user = files.filter((f) => f.ownership === "user");
    const tests = files.filter((f) => f.ownership !== "user" && f.placement === "test");
    const support = files.filter((f) => f.ownership !== "user" && f.placement !== "test");
    const entries = [];
    const item = (file, kind) => {
      const b = button(file.path.split("/").pop(), file.path, () => this.open(file, kind));
      b.dataset.path = file.path;
      b.classList.add(kind);
      entries.push({ file, kind });
      return element("li", {}, [b]);
    };
    const section = (title, list, kind, collapsed = false) => {
      if (!list.length) return [];
      const items = element("ul", {}, list.map((f) => item(f, kind)));
      return collapsed
        ? [element("details", {}, [element("summary", { text: `${title} (${list.length})` }), items])]
        : [element("div", { class: "heading", text: title }), items];
    };
    this.fileList.replaceChildren(
      ...section("Specification", [{ path: this.model.path }], "spec"),
      ...section("Your implementation", user, "implementation"),
      ...section("Generated tests · read-only", tests, "test"),
      ...section("Generated support · read-only", support, "support", true),
      ...(partial ? [button("Show generated code", "Compile the specification for this language", () => this.generateFiles(this.openKind()), { class: "more" })] : []));
    const wanted = open === "spec" || open === "implementation"
      ? entries.find((e) => e.kind === open) : entries.find((e) => e.file.path === open);
    const chosen = wanted ?? (open === "implementation" ? null : entries[0]);
    if (chosen) this.open(chosen.file, chosen.kind);
    // An implementation not known before compiling appears once compiled.
    if (!chosen && partial) this.generateFiles(open);
  }

  async generateFiles(open) {
    this.status.textContent = `Generating ${this.target}…`;
    try {
      const result = await this.model.generate(this.target);
      if (result.diagnostics.length) return this.showDiagnostics(result.diagnostics);
      this.status.textContent = "";
      this.renderFiles(result.files, false, open);
    } catch (error) {
      this.status.textContent = `Cannot compile: ${error.message}`;
    }
  }

  open(file, kind) {
    this.selected = { file, kind };
    for (const b of this.fileList.querySelectorAll("button[data-path]"))
      b.setAttribute("aria-current", String(b.dataset.path === file.path));
    let pane;
    if (kind === "spec") {
      this.currentText = this.model.spec;
      pane = editablePane(this.model.spec, "lawspec", `Specification ${file.path}`, (text) => {
        this.currentText = text;
        this.model.setSpec(text, this);
      });
    } else if (kind === "implementation") {
      this.currentText = this.model.implementation(this.target, file);
      pane = editablePane(this.currentText, languageOf(file.path), `Your implementation ${file.path}`, (text) => {
        this.currentText = text;
        this.model.setImplementation(this.target, file.path, text, this);
      });
    } else {
      this.currentText = file.content;
      pane = readOnlyPane(file.content, languageOf(file.path));
    }
    const note = kind === "spec" ? "the specification · editable"
      : kind === "implementation" ? `your implementation · editable${runnable.has(this.target) ? " · ▶ Run tests it" : ""}`
      : "generated by LawSpec · read-only";
    this.pane.replaceChildren(element("div", { class: `pane-label ${kind}`, text: `${file.path} — ${note}` }), pane);
  }

  show(...nodes) {
    this.output.hidden = false;
    this.output.replaceChildren(...nodes);
  }

  showDiagnostics(diagnostics) {
    this.show(element("pre", { class: "failure", text: diagnostics.map((d) =>
      `${d.at ? `${d.at.file}:${d.at.line}:${d.at.column}: ` : ""}${d.code}: ${d.message}`).join("\n") }));
    this.status.textContent = "The specification does not compile.";
  }

  // Compile, and list each law of this example's unit with its evidence.
  async check() {
    this.status.textContent = "Compiling…";
    try {
      const result = await (await loadCompiler()).check({ sources: this.model.sources() });
      if (result.diagnostics.length) return this.showDiagnostics(result.diagnostics);
      const unit = /^\s*unit\s+([\w.]+)/m.exec(this.model.spec)?.[1];
      const laws = (result.evidence ?? []).filter((e) => e.stage === "law" && e.owner === unit);
      this.show(element("ul", { class: "results" }, laws.map((law) => element("li", {}, [
        element("span", { class: `badge ${law.status}`, text: statusLabels[law.status] }), " ",
        element("strong", { text: law.declaration.split("::law::").pop() }),
        element("div", { class: "detail", text: law.reason }),
      ]))));
      this.status.textContent = `Compiles: ${laws.length} law${laws.length === 1 ? "" : "s"}.`;
    } catch (error) {
      this.status.textContent = `Cannot compile: ${error.message}`;
    }
  }

  // Generate the tests from the current specification and run them against
  // the implementation as edited. Tests and support code are LawSpec's.
  async run() {
    if (!runnable.has(this.target)) return;
    this.status.textContent = "Generating the tests…";
    try {
      const result = await this.model.generate(this.target);
      if (result.diagnostics.length) return this.showDiagnostics(result.diagnostics);
      // Show the tests that run: those of the current specification.
      if (this.renderedSpec !== this.model.spec) this.renderFiles(result.files, false, this.openKind());
      let modules = Object.fromEntries(result.files.map((f) =>
        [f.path, f.ownership === "user" ? this.model.implementation(this.target, f) : f.content]));
      if (this.target === "typescript") {
        this.status.textContent = "Transpiling TypeScript…";
        modules = await transpile(modules);
      }
      const tests = Object.keys(modules).filter((path) => /^test\/.*\.test\.(mjs|js)$/.test(path));
      this.status.textContent = "Running in the sandbox…";
      const started = performance.now();
      const results = await runInSandbox(modules, tests);
      this.report(results, performance.now() - started);
    } catch (error) {
      this.show(element("pre", { class: "failure", text: error.message }));
      this.status.textContent = "The tests could not run.";
    }
  }

  // One entry per law: its examples, its boundary cases and its generated
  // cases, each with the failure message when it fails.
  report(results, elapsed) {
    const laws = new Map();
    for (const r of results) {
      const example = /^(.*?) example: (.*)$/.exec(r.name);
      const property = r.name.endsWith(" property");
      const law = example ? example[1] : property ? r.name.slice(0, -" property".length) : r.name;
      const entry = laws.get(law) ?? { examples: [], boundaries: [], properties: [] };
      if (example) entry.examples.push({ ...r, label: `example “${example[2]}”` });
      else if (property) entry.properties.push({ ...r, label: "generated cases" });
      else entry.boundaries.push(r);
      laws.set(law, entry);
    }
    let failed = 0;
    const list = element("ul", { class: "results" }, [...laws].map(([law, { examples, boundaries, properties }]) => {
      const groups = [
        ...examples.map((r) => [r.label, [r]]),
        ...(boundaries.length ? [[`${boundaries.length} boundary case${boundaries.length === 1 ? "" : "s"}`, boundaries]] : []),
        ...properties.map((r) => [r.label, [r]]),
      ];
      const ok = groups.every(([, rs]) => rs.every((r) => r.ok));
      if (!ok) failed++;
      return element("li", { class: ok ? "pass" : "fail" }, [
        element("span", { class: "mark", text: ok ? "✓" : "✗" }), " ",
        element("strong", { text: law.split("::").pop() }),
        element("ul", {}, groups.map(([label, rs]) => {
          const failure = rs.find((r) => !r.ok);
          return element("li", { class: failure ? "fail" : "pass" }, [`${failure ? "✗" : "✓"} ${label}`,
            ...(failure ? [element("pre", { class: "failure", text: failure.error })] : [])]);
        })),
      ]);
    }));
    this.show(list);
    const verdict = failed ? `${failed} of ${laws.size} law${laws.size === 1 ? "" : "s"} failed`
      : laws.size === 1 ? "The law holds" : `All ${laws.size} laws hold`;
    this.status.textContent = `${verdict} (${results.length} tests, ${Math.round(elapsed)} ms).`;
  }
}

// The sandbox's library modules: shims for node:test and node:assert, and
// the vendored property-testing libraries, fetched once from this site.
let library;
function loadLibrary() {
  library ??= fetch(new URL("vendor/sandbox.json", assets)).then((r) => r.json()).then(async (manifest) => {
    const modules = {};
    await Promise.all(Object.entries(manifest.modules).map(async ([path, url]) => {
      modules[path] = await (await fetch(new URL(url, assets))).text();
    }));
    return { modules, aliases: manifest.aliases };
  });
  return library;
}

// A fresh opaque-origin frame per run. It receives every module as text,
// links them itself as blob modules, and can fetch nothing: its content
// security policy allows only inline and blob scripts, and its origin gives
// it no access to this page or its storage. A run that does not finish in
// time is discarded with its frame.
async function runInSandbox(generated, tests, timeout = 60000) {
  const { modules, aliases } = await loadLibrary();
  return new Promise((resolve, reject) => {
    const frame = element("iframe", { sandbox: "allow-scripts", hidden: true, title: "LawSpec test sandbox" });
    const timer = setTimeout(() => { done(); reject(new Error(`The tests did not finish within ${timeout / 1000} seconds.`)); }, timeout);
    const done = () => { clearTimeout(timer); window.removeEventListener("message", listen); frame.remove(); };
    const listen = (event) => {
      if (event.source !== frame.contentWindow) return;
      if (event.data?.ready) frame.contentWindow.postMessage({ modules: { ...modules, ...generated }, aliases, tests }, "*");
      else if (event.data?.results) { done(); resolve(event.data.results); }
      else if (event.data?.error) { done(); reject(new Error(event.data.error)); }
    };
    window.addEventListener("message", listen);
    frame.srcdoc = "<!doctype html><meta charset=utf-8>" +
      `<meta http-equiv="Content-Security-Policy" content="default-src 'none'; script-src 'unsafe-inline' blob:">` +
      `<script>(${sandboxMain.toString()})()<\/script>`;
    document.body.append(frame);
  });
}

// Runs inside the sandbox.
function sandboxMain() {
  const join = (from, relative) => {
    const parts = from.split("/").slice(0, -1);
    for (const part of relative.split("/")) {
      if (part === "..") parts.pop();
      else if (part !== ".") parts.push(part);
    }
    return parts.join("/");
  };
  addEventListener("message", async ({ data: { modules, aliases, tests } }) => {
    try {
      const urls = new Map();
      const resolve = (from, specifier) => {
        if (specifier.startsWith("./") || specifier.startsWith("../")) return join(from, specifier);
        if (specifier in aliases) return aliases[specifier];
        throw new Error(`${from} imports ${specifier}, which the sandbox does not provide`);
      };
      const link = (path) => {
        if (urls.has(path)) return urls.get(path);
        if (!(path in modules)) throw new Error(`missing module ${path}`);
        // Import and export statements start a line; comments and strings
        // that merely mention "from" are left alone.
        const rewrite = (_, prefix, quote, specifier) => `${prefix}${quote}${link(resolve(path, specifier))}${quote}`;
        const code = modules[path]
          .replace(/^([ \t]*(?:import|export)\b[^;'"`]*?\bfrom\s*)(['"])([^'"\n]+)\2/gm, rewrite)
          .replace(/^([ \t]*import\s*)(['"])([^'"\n]+)\2/gm, rewrite)
          .replace(/(\bimport\s*\(\s*)(['"])([^'"\n]+)\2/g, rewrite);
        const url = URL.createObjectURL(new Blob([code], { type: "text/javascript" }));
        urls.set(path, url);
        return url;
      };
      for (const test of tests) await import(link(test));
      const results = [];
      for (const { name, fn } of globalThis.__lawspecTests ?? []) {
        try { await fn(); results.push({ name, ok: true }); }
        catch (error) { results.push({ name, ok: false, error: String(error?.message ?? error) }); }
      }
      parent.postMessage({ results }, "*");
    } catch (error) {
      parent.postMessage({ error: String(error?.message ?? error) }, "*");
    }
  });
  parent.postMessage({ ready: true }, "*");
}

customElements.define("lawspec-playground", Playground);
highlightPage();
