// Generated from templates/npm/lsp.mjs by lawspec-dev generate. Do not edit.
import { readFile, readdir, stat } from 'node:fs/promises';
import { fileURLToPath, pathToFileURL } from 'node:url';
import path from 'node:path';
import { createCompiler } from './api.mjs';

export function utf16Position(text, location) {
  const line = Math.max(0, location.line - 1);
  const content = text.split('\n')[line] ?? '';
  let column = 1, character = 0;
  for (const value of content) {
    if (column >= location.column) break;
    column += value === '\t' ? 8 - ((column - 1) % 8) : 1;
    character += value.length;
  }
  return { line, character };
}
const endPosition = text => {
  const lines = text.split('\n');
  return { line: lines.length - 1, character: lines.at(-1).length };
};
const within = (position, range) => (position.line > range.start.line || position.line === range.start.line && position.character >= range.start.character)
  && (position.line < range.end.line || position.line === range.end.line && position.character < range.end.character);

// A framed JSON-RPC transport keeps UTF-8 byte lengths distinct from editor
// UTF-16 positions. It accepts fragmented and coalesced messages.
export async function serveLanguage(input = process.stdin, output = process.stdout, suppliedCompiler) {
  const compiler = suppliedCompiler ?? await createCompiler();
  const documents = new Map();
  let workspace = process.cwd(), buffer = Buffer.alloc(0), queue = Promise.resolve(), shuttingDown = false;
  let last = { sources: [], result: null }, warnMatches = false;
  let finish;
  const ended = new Promise(resolve => { finish = resolve; });
  const send = value => {
    const payload = Buffer.from(JSON.stringify(value));
    output.write(`Content-Length: ${payload.length}\r\n\r\n`);
    output.write(payload);
  };
  async function projectSources() {
    const sources = new Map();
    async function visit(file) {
      const info = await stat(file);
      if (info.isDirectory()) for (const name of (await readdir(file)).sort()) await visit(path.join(file, name));
      else if (file.endsWith('.lawspec')) sources.set(file, { path: file, content: await readFile(file, 'utf8') });
    }
    let config;
    try { config = JSON.parse(await readFile(path.join(workspace, 'lawspec.json'), 'utf8')); }
    catch (error) { if (error.code !== 'ENOENT') throw error; }
    if(config&&(config.version!==2||config.languageProfile!=='1.0-rc.2'))
      throw new Error('The language server requires configuration version 2 and languageProfile 1.0-rc.2.');
    for (const entry of config?.sources ?? []) await visit(path.resolve(workspace, entry));
    for (const [uri, document] of documents) sources.set(fileURLToPath(uri), { path: fileURLToPath(uri), content: document.text });
    return [...sources.values()];
  }
  function location(location, sources = last.sources) {
    const source = sources.find(s => s.path === location.file);
    if (!source) return null;
    return { uri: pathToFileURL(source.path).href, position: utf16Position(source.content, location) };
  }
  function span(span) {
    const start = location(span.start ?? span.spanStart), end = location(span.end ?? span.spanEnd);
    return start && end ? { uri: start.uri, range: { start: start.position, end: end.position } } : null;
  }
  async function check() {
    const sources = await projectSources();
    const result = await compiler.check({ sources, languageProfile: '1.0-rc.2', verification: { layers: [] }, ...(warnMatches ? {warnMatches:true} : {}) });
    last = { sources, result };
    for (const [uri, document] of documents) {
      const file = fileURLToPath(uri);
      const diagnostics = [...(result.diagnostics ?? []), ...(warnMatches ? result.warnings ?? [] : [])].filter(d => !d.at || d.at.file === file).map(d => {
        const start = d.at ? utf16Position(document.text, d.at) : { line: 0, character: 0 };
        const content = document.text.split('\n')[start.line] ?? '';
        const end = { ...start, character: Math.min(content.length, start.character + ([...content.slice(start.character)][0]?.length ?? 0)) };
        const range = d.span ? span(d.span)?.range ?? {start,end} : {start,end};
        return { range, severity: d.severity === 'warning' ? 2 : 1, code: d.code, source: 'LawSpec', message: d.message,
          ...(d.related?.length ? {relatedInformation: d.related.flatMap(item => {
            const origin = span(item.span);
            return origin ? [{location: {uri: origin.uri, range: origin.range}, message: item.message}] : [];
          })} : {}) };
      });
      send({ jsonrpc: '2.0', method: 'textDocument/publishDiagnostics', params: { uri, version: document.version, diagnostics } });
    }
  }
  function declarations() {
    const result = last.result;
    if (!result) return [];
    const entries = [];
    for (const unit of result.units ?? []) for (const d of unit.declarations) {
      const origin = d.origin?.kind === 'source' ? span(d.origin.span) : null;
      if (origin) entries.push({ id: d.id, name: d.name, kind: 12, detail: JSON.stringify(d.type), ...origin });
    }
    for (const d of result.dataTypes ?? []) {
      const origin = d.origin?.kind === 'source' ? span(d.origin.span) : null;
      if (origin) entries.push({ id: d.id, name: d.name, kind: 23, detail: 'Type', ...origin });
    }
    for (const law of result.laws ?? []) {
      const origin = location(law.location);
      if (origin) entries.push({ id: law.id, name: law.name, kind: 12, detail: law.description || 'Law', uri: origin.uri,
        range: { start: origin.position, end: { ...origin.position, character: origin.position.character + 3 } } });
    }
    return entries;
  }
  function documentaryLinks() {
    return (last.result?.laws ?? []).flatMap(law => (law.references ?? [])
      .filter(reference => reference?.kind === 'law' || reference?.kind === 'function'));
  }
  function documentaryDeclaration(id) {
    const reference = documentaryLinks().find(reference => reference.target.id === id);
    const target = reference?.target, origin = target && span(target.span);
    return origin ? { id, name: target.name, detail: reference.kind === 'law' ? 'Law' : 'Function', ...origin } : null;
  }
  function uses() {
    const result = last.result;
    if (!result) return [];
    const entries = [];
    function walk(value) {
      if (!value || typeof value !== 'object') return;
      if (value.node?.kind === 'call' && value.origin?.kind === 'source') {
        const origin = span(value.origin.span);
        if (origin) entries.push({ id: value.node.declaration, ...origin });
      }
      for (const child of Object.values(value)) if (typeof child === 'object') {
        if (Array.isArray(child)) child.forEach(walk); else walk(child);
      }
    }
    walk(result.laws); walk(result.definitions);
    for (const reference of documentaryLinks()) {
      const origin = span(reference.target.referenceSpan);
      if (origin) entries.push({ id: reference.target.id, ...origin });
    }
    return entries;
  }
  function selected(params) {
    const candidates = [...uses(), ...declarations()].filter(d => d.uri === params.textDocument.uri && within(params.position, d.range));
    candidates.sort((a, b) => (a.range.end.line - a.range.start.line) - (b.range.end.line - b.range.start.line)
      || (a.range.end.character - a.range.start.character) - (b.range.end.character - b.range.start.character));
    return candidates[0];
  }
  async function handle(message) {
    const params = message.params ?? {};
    let result = null;
    switch (message.method) {
      case 'initialize':
        if (params.initializationOptions?.warnMatches !== undefined && typeof params.initializationOptions.warnMatches !== 'boolean')
          throw new Error('warnMatches must be a Boolean');
        warnMatches = params.initializationOptions?.warnMatches ?? false;
        workspace = params.rootUri ? fileURLToPath(params.rootUri) : params.rootPath ?? workspace;
        result = { capabilities: { textDocumentSync: 1, positionEncoding: 'utf-16', documentFormattingProvider: true,
          documentSymbolProvider: true, hoverProvider: true, definitionProvider: true, referencesProvider: true },
          serverInfo: { name: 'LawSpec', version: '1.0-rc.2' } };
        break;
      case 'initialized': break;
      case 'workspace/didChangeConfiguration': {
        const next = params.settings?.lawspec?.warnMatches;
        if (next !== undefined && typeof next !== 'boolean') throw new Error('lawspec.warnMatches must be a Boolean');
        warnMatches = next ?? false;
        await check(); break;
      }
      case 'shutdown': shuttingDown = true; break;
      case 'exit': input.pause(); finish(); return;
      case 'textDocument/didOpen': documents.set(params.textDocument.uri, params.textDocument); await check(); break;
      case 'textDocument/didChange': {
        const document = documents.get(params.textDocument.uri);
        if (params.contentChanges.some(change => change.range)) throw new Error('LawSpec requires full-document synchronization');
        if (document && params.contentChanges.length) documents.set(params.textDocument.uri, {
          ...document, text: params.contentChanges.at(-1).text, version: params.textDocument.version });
        await check(); break;
      }
      case 'textDocument/didClose': documents.delete(params.textDocument.uri);
        send({ jsonrpc: '2.0', method: 'textDocument/publishDiagnostics', params: { uri: params.textDocument.uri, diagnostics: [] } }); break;
      case 'textDocument/formatting': {
        const document = documents.get(params.textDocument.uri);
        if (!document) { result = []; break; }
        const sourcePath = fileURLToPath(params.textDocument.uri);
        const response = await compiler.format({ sources: await projectSources(), languageProfile: '1.0-rc.2', verification: { layers: [] } });
        if (response.diagnostics?.length) { result = []; break; }
        const formatted = response.formattedSources.find(s => s.path === sourcePath);
        result = formatted && formatted.content !== document.text
          ? [{ range: { start: { line: 0, character: 0 }, end: endPosition(document.text) }, newText: formatted.content }] : [];
        break;
      }
      case 'textDocument/documentSymbol': result = declarations().filter(d => d.uri === params.textDocument.uri)
        .map(d => ({ name: d.name, detail: d.detail, kind: d.kind, range: d.range, selectionRange: d.range })); break;
      case 'textDocument/hover': {
        const use = selected(params), declaration = use && (declarations().find(d => d.id === use.id) ?? documentaryDeclaration(use.id));
        result = declaration ? { contents: { kind: 'plaintext', value: `${declaration.name}\n${declaration.detail}` }, range: use.range } : null;
        break;
      }
      case 'textDocument/definition': {
        const use = selected(params), declaration = use && (declarations().find(d => d.id === use.id) ?? documentaryDeclaration(use.id));
        result = declaration ? { uri: declaration.uri, range: declaration.range } : null;
        break;
      }
      case 'textDocument/references': {
        const use = selected(params);
        const declared = use && (declarations().find(d => d.id === use.id) ?? documentaryDeclaration(use.id));
        result = use ? [...uses(), ...(params.context?.includeDeclaration && declared ? [declared] : [])].filter(d => d.id === use.id)
          .map(d => ({ uri: d.uri, range: d.range })) : [];
        break;
      }
      case '$/cancelRequest': break;
      default: if (message.id !== undefined) send({ jsonrpc: '2.0', id: message.id, error: { code: -32601, message: 'Method not found' } }); return;
    }
    if (message.id !== undefined) send({ jsonrpc: '2.0', id: message.id, result });
  }
  input.on('data', data => {
    buffer = Buffer.concat([buffer, data]);
    for (;;) {
      const headerEnd = buffer.indexOf('\r\n\r\n');
      if (headerEnd < 0) break;
      const length = /^Content-Length:\s*(\d+)\s*$/im.exec(buffer.subarray(0, headerEnd).toString());
      if (!length || Number(length[1]) > 16 * 1024 * 1024) {
        send({ jsonrpc: '2.0', id: null, error: { code: -32700, message: 'Invalid Content-Length' } }); input.pause(); finish(); break;
      }
      const end = headerEnd + 4 + Number(length[1]);
      if (buffer.length < end) break;
      const body = buffer.subarray(headerEnd + 4, end); buffer = buffer.subarray(end);
      queue = queue.then(async () => {
        let message;
        try { message = JSON.parse(body.toString()); }
        catch { send({ jsonrpc: '2.0', id: null, error: { code: -32700, message: 'Parse error' } }); return; }
        try {
          if (shuttingDown && !['exit', 'shutdown'].includes(message.method)) throw new Error('Server is shutting down');
          await handle(message);
        } catch (error) {
          if (message.id !== undefined) send({ jsonrpc: '2.0', id: message.id, error: { code: -32603, message: error.message } });
          else send({ jsonrpc: '2.0', method: 'window/logMessage', params: { type: 1, message: error.message } });
        }
      });
    }
  });
  input.once('end', finish);
  await ended;
  await queue;
}
