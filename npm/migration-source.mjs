// Generated from templates/npm/migration-source.mjs by lawspec-dev generate. Do not edit.
// Source edits use the checked legacy compiler's declaration/expression spans.
// This module plans edits; semantic correspondence and project writes belong
// to the migration coordinator, not this lexical layer.
export function migrationTokens(content) {
  const result = [];
  for (let offset = 0; offset < content.length;) {
    const start = offset;
    let kind;
    const rest = content.slice(offset);
    if (rest.startsWith('--')) {
      kind = 'comment';
      offset = content.indexOf('\n', offset);
      if (offset < 0) offset = content.length;
    } else if (/^\s/u.test(rest)) {
      kind = 'trivia';
      offset += /^\s+/u.exec(rest)[0].length;
    } else if (rest[0] === '"' || rest[0] === '`') {
      const delimiter = rest[0];
      kind = delimiter === '"' ? 'string' : 'quoted';
      offset++;
      let closed = false;
      while (offset < content.length) {
        const character = content[offset++];
        if (delimiter === '"' && character === '\\') {
          if (offset >= content.length) throw new Error('Unterminated migration string escape');
          offset++;
        } else if (character === delimiter) { closed = true; break; }
      }
      if (!closed) throw new Error('Unterminated migration ' + kind);
    } else {
      const word = /^[\p{L}\p{N}_]+/u.exec(rest);
      if (word) { kind = 'word'; offset += word[0].length; }
      else {
        kind = 'symbol';
        const symbol = /^(?:::|->|==|!=|<=|>=|&&|\|\||\+\+|>>=|<\$>|<!>|<\|>|>=>|<\*>|\?\?|\|>)/.exec(rest);
        offset += symbol ? symbol[0].length : String.fromCodePoint(content.codePointAt(offset)).length;
      }
    }
    result.push({kind, start, end: offset, text: content.slice(start, offset)});
  }
  return result;
}

// Megaparsec columns count Unicode code points and expand tabs to eight-column
// stops; JavaScript offsets count UTF-16 units. Neither is a byte offset.
export function migrationOffset(content, location) {
  if (!Number.isInteger(location.line) || !Number.isInteger(location.column) || location.line < 1 || location.column < 1)
    throw new Error('Invalid migration source location');
  let offset = 0;
  for (let line = 1; line < location.line; line++) {
    const newline = content.indexOf('\n', offset);
    if (newline < 0) throw new Error('Migration source line is out of bounds');
    offset = newline + 1;
  }
  let column = 1;
  while (column < location.column && offset < content.length && content[offset] !== '\n') {
    const character = String.fromCodePoint(content.codePointAt(offset));
    const next = character === '\t' ? column + 8 - (column - 1) % 8 : column + 1;
    if (next > location.column) throw new Error('Migration source location is inside a tab');
    column = next;
    offset += character.length;
  }
  if (column !== location.column) throw new Error('Migration source column is out of bounds');
  return offset;
}

export class MigrationDocument {
  constructor(source) {
    this.path = source.path;
    this.content = source.content;
    this.tokens = migrationTokens(source.content);
    this.edits = [];
  }
  range(origin) {
    if (origin?.kind !== 'source' || origin.span.start.file !== this.path || origin.span.end.file !== this.path) return null;
    const start = migrationOffset(this.content, origin.span.start);
    const end = migrationOffset(this.content, origin.span.end);
    if (end < start) throw new Error('Reversed migration source span');
    return {start, end};
  }
  code(start = 0, end = this.content.length) {
    return this.tokens.filter(token => token.start >= start && token.end <= end && !['trivia','comment'].includes(token.kind));
  }
  edit(start, end, content, reason, identity = reason + ':' + start + ':' + end) {
    if (!Number.isInteger(start) || !Number.isInteger(end) || start < 0 || end < start || end > this.content.length)
      throw new Error('Migration edit is out of bounds');
    const same = this.edits.find(edit => edit.identity === identity);
    if (same) {
      if (same.start !== start || same.end !== end || same.content !== content) throw new Error('Inconsistent migration edit identity');
      return;
    }
    for (const previous of this.edits) {
      if (Math.max(start, previous.start) < Math.min(end, previous.end) ||
          (start === end && previous.start < start && start < previous.end) ||
          (previous.start === previous.end && start < previous.start && previous.start < end))
        throw new Error('Overlapping migration edits');
    }
    this.edits.push({start, end, content, reason, identity, before: this.content.slice(start,end)});
  }
  result() {
    const edits = this.edits.map((edit, order) => ({...edit, order})).sort((a,b) =>
      a.start - b.start || a.end - b.end || a.order - b.order);
    const segments = [];
    let output = '', offset = 0;
    for (const edit of edits) {
      if (edit.start < offset) throw new Error('Migration edit ordering overlaps');
      const retained = this.content.slice(offset, edit.start);
      segments.push({start:output.length, end:output.length + retained.length, originalStart:offset, originalEnd:edit.start, retained:true});
      output += retained;
      segments.push({start:output.length, end:output.length + edit.content.length, originalStart:edit.start, originalEnd:edit.end, retained:false, reason:edit.reason});
      output += edit.content;
      offset = edit.end;
    }
    segments.push({start:output.length, end:output.length + this.content.length - offset, originalStart:offset, originalEnd:this.content.length, retained:true});
    output += this.content.slice(offset);
    return {path:this.path, content:output, edits:edits.map(({order, ...edit}) => edit), segments};
  }
}

function walk(value, visit) {
  if (!value || typeof value !== 'object') return;
  visit(value);
  for (const child of Object.values(value)) {
    if (Array.isArray(child)) child.forEach(item => walk(item, visit));
    else if (child && typeof child === 'object') walk(child, visit);
  }
}

export function planLegacyComputationEdits(sources, baseline, sourceSyntax = []) {
  if (baseline.diagnostics?.length) throw new Error('Migration requires a checked legacy baseline');
  const documents = new Map(sources.map(source => [source.path,new MigrationDocument(source)]));
  if (documents.size !== sources.length) throw new Error('Duplicate migration source path');
  for (const source of sourceSyntax) {
    if (source.version !== 1 || !Array.isArray(source.nodes)) throw new Error('Unsupported checked source syntax inventory');
    for (const node of source.nodes) if (!node.span?.start?.file || !node.span?.end?.file)
      throw new Error('Malformed checked source syntax span');
  }
  const parsedDeclarations = sourceSyntax.flatMap(source => source.nodes.filter(node => node.kind === 'declaration.definition')
    .map(node => {
      if (!Array.isArray(node.uses)) throw new Error('A checked source definition has no effect context');
      return {origin:{kind:'source',span:node.span},uses:node.uses};
    }));
  const declarations = [...parsedDeclarations,...(baseline.units ?? []).flatMap(unit => unit.declarations ?? [])];
  for (const declaration of declarations) {
    const document = documents.get(declaration.origin?.span?.start?.file);
    const range = document?.range(declaration.origin);
    if (!range) continue;
    const tokens = document.code(range.start, range.end);
    if (tokens[0]?.text !== 'definition') continue;
    const kind = declaration.uses?.length || declaration.async ? 'procedure' : 'function';
    document.edit(tokens[0].start,tokens[0].end,kind,'computation declaration');
    let depth = 0, annotation;
    for (const token of tokens.slice(2)) {
      if (['(','[','{'].includes(token.text)) depth++;
      else if ([')',']','}'].includes(token.text)) depth--;
      else if (depth === 0 && token.text === '::') { annotation = token; break; }
      else if (depth === 0 && token.text === 'is') break;
    }
    if (!annotation || tokens.at(-1)?.text !== 'end') throw new Error('Checked definition span does not identify its result and closer');
    document.edit(annotation.start,annotation.end,'->','computation result');
    const closer = tokens.at(-1);
    document.edit(closer.start,closer.end,'end ' + kind,'computation closer');
  }
  for (const source of sourceSyntax) for (const node of source.nodes) {
    const document = documents.get(node.span?.start?.file);
    const range = document?.range({kind:'source',span:node.span});
    if (!range) continue;
    if (node.kind === 'if') {
      const tokens = document.code(range.start,range.end);
      if (tokens[0]?.text !== 'if' || !tokens.at(-1)) throw new Error('Checked conditional syntax has no source block');
      document.edit(tokens.at(-1).end,tokens.at(-1).end,' end if','conditional closer','conditional:' + tokens[0].start);
    }
    if (node.kind === 'operator.value-equality') {
      const tokens = document.code(range.start,range.end);
      if (tokens.length !== 1 || tokens[0].text !== '==') throw new Error('Checked equality syntax has no operator token');
      document.edit(tokens[0].start,tokens[0].end,'=','typed equality');
    }
  }
  walk(baseline, expression => {
    if (expression.node?.kind === 'binary' && expression.node.operator === '==') {
      const document = documents.get(expression.origin?.span?.start?.file);
      const parent = document?.range(expression.origin);
      if (parent) {
        // Lowered constructors and intrinsic calls may have generated origins;
        // their source-bearing descendants still bound the operator. Never
        // choose among multiple candidates or infer a type from token spelling.
        const ranges = value => {
          const found = [];
          walk(value, child => {
            const range = document.range(child.origin);
            if (range && range.start >= parent.start && range.end <= parent.end) found.push(range);
          });
          return found;
        };
        const start = Math.max(parent.start,...ranges(expression.node.left).map(range => range.end));
        const end = Math.min(parent.end,...ranges(expression.node.right).map(range => range.start));
        const operators = start <= end ? document.code(start,end).filter(token => token.text === '==') : [];
        if (operators.length === 1) {
          const operator = operators[0];
          document.edit(operator.start,operator.end,'=','typed equality');
        }
      }
    }
    if (expression.node?.kind !== 'if') return;
    const document = documents.get(expression.origin?.span?.start?.file);
    const range = document?.range(expression.origin);
    const condition = document?.range(expression.node.condition?.origin);
    const alternative = document?.range(expression.node.else?.origin);
    if (!range || !condition || !alternative) return;
    const prefix = document.code(range.start,condition.start);
    const opener = prefix.find(token => token.text === 'if');
    if (!opener) return; // A select call or generated condition is not an if block.
    if (prefix.some(token => token.start < opener.start && token.text !== '(')) return;
    const last = document.code(alternative.start,alternative.end).at(-1);
    if (!last) throw new Error('Checked conditional has no source alternative');
    document.edit(last.end,last.end,' end if','conditional closer','conditional:' + opener.start);
  });
  for (const document of documents.values()) for (const token of document.tokens) {
    if (token.kind !== 'string' || !token.text.startsWith('"|')) continue;
    // Decimal escapes terminate at the next backslash. Escape any immediately
    // following decimal digits too, so a literal such as "|123" stays exact.
    const digits = /^\d*/.exec(token.text.slice(2))[0];
    const escaped = '"\\124' + [...digits].map(digit => '\\' + digit.charCodeAt(0)).join('') + token.text.slice(2 + digits.length);
    document.edit(token.start,token.end,escaped,'literal reserved prefix');
  }
  return [...documents.values()].map(document => document.result());
}
