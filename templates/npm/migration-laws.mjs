// Law edits consume the original parser's checked source inventory. They
// deliberately target the current minor grammar; its remaining plain closers
// are superseded by the following milestone's all-named-ending requirement.
import {MigrationDocument,planLegacyComputationEdits} from './migration-source.mjs';
import {planLegacyCases} from './migration-cases.mjs';
import {planLegacyRecords,legacyRecordShapes} from './migration-records.mjs';
import {planLegacyCollectionNames} from './migration-collections.mjs';

function phrase(name) {
  if (!name || name.trim() !== name || /[\r\n]/.test(name))
    throw new Error('Legacy quoted names with empty bodies or edge whitespace need an explicit rename');
  return '"|' + name.replace(/[\\|]/g,character => '\\'+character) + '|';
}

export function planLegacySourceEdits(sources, baseline, sourceSyntax, sourceFields) {
  const computations = planLegacyComputationEdits(sources,baseline,sourceSyntax);
  const documents = new Map(sources.map(source => [source.path,new MigrationDocument(source)]));
  for (const source of computations) documents.get(source.path).edits.push(...source.edits);
  const indexed=sourceSyntax.filter(source=>documents.has(source.path)).map(source=>{
    const document=documents.get(source.path);
    const nodes=source.nodes.map(node=>({...node,...document.range({kind:'source',span:node.span})}));
    if (nodes.some(node=>!Number.isInteger(node.start))) throw new Error('Source inventory belongs to a different migration document');
    return {...source,nodes,fieldUses:sourceFields?.status==='available' ? sourceFields.uses.filter(use=>use.span.start.file===source.path) : null};
  });
  const shapes=legacyRecordShapes(indexed);
  for (const source of indexed) {
    const document = documents.get(source.path);
    if (!document) continue;
    const nodes=source.nodes;
    const contains = (outer,inner) => outer.start <= inner.start && inner.end <= outer.end;
    const code = node => document.code(node.start,node.end);
    const first = node => code(node)[0];
    const replaceToken = (token,content,reason) => {
      if (!token) throw new Error('Checked source node has no token for '+reason);
      document.edit(token.start,token.end,content,reason);
    };
    const headerDelimiter = (node,word) => {
      let depth = 0;
      return code(node).find(token => {
        if (['(','[','{'].includes(token.text)) depth++;
        if ([')',']','}'].includes(token.text)) depth--;
        return depth === 0 && token.text === word;
      });
    };
    planLegacyCollectionNames(document,source);
    planLegacyRecords(document,source,shapes);
    planLegacyCases(document,nodes);
    for (const node of nodes) {
      if (node.kind === 'quoted-name') {
        // Scenarios and benchmark labels retain their existing quoted syntax.
        if (nodes.some(parent => ['declaration.scenario','benchmark'].includes(parent.kind) && contains(parent,node))) continue;
        const token = first(node);
        if (token?.kind !== 'quoted') throw new Error('Checked quoted name has no legacy delimiter');
        const marker = nodes.some(parent => ['import','export'].includes(parent.kind) && contains(parent,node)) ? 'law ' : '';
        replaceToken(token,marker+phrase(node.name),'quoted law or example name');
      }
      if (node.kind === 'law-reference')
        document.edit(node.start,node.start,'apply law ','reusable law application');
      if (node.kind === 'section') {
        const tokens = code(node);
        const delimiter = tokens[1];
        if (tokens[0]?.text !== node.name || !['is','are'].includes(delimiter?.text))
          throw new Error('Checked law section has no legacy delimiter');
        replaceToken(delimiter,':','law section delimiter');
      }
      if (node.kind === 'example') {
        replaceToken(headerDelimiter(node,'is'),':','example delimiter');
      }
      if (node.kind === 'quantifier.forall') {
        const tokens = code(node);
        if (tokens[0]?.text !== '`for all`') throw new Error('Checked universal quantifier has no legacy opener');
        replaceToken(tokens[0],'for all','universal quantifier');
        replaceToken(headerDelimiter(node,'.'),'=>','universal binder delimiter');
        // Source inventory is in completion order, so nested quantifiers at
        // the same offset close inside out, after any inner conditional.
        document.edit(tokens.at(-1).end,tokens.at(-1).end,' end','universal scope','universal:'+node.start);
      }
    }
    // Expectations move as one lossless source range. Comments, line breaks,
    // recorded names and child expression edits accompany the moved text.
    for (const table of nodes.filter(node => node.kind === 'table')) {
      const expectations = nodes.filter(node => node.kind === 'table-expectation' && contains(table,node));
      if (!expectations.length) throw new Error('A legacy table without expectations needs an explicit authoring decision');
      const start = Math.min(...expectations.map(node => node.start));
      const end = Math.max(...expectations.map(node => node.end));
      const opener = first(table);
      if (opener?.text !== 'table') throw new Error('Checked table has no legacy opener');
      replaceToken(headerDelimiter(table,'is'),':','table delimiter');
      document.moveBefore(start,end,opener.start,'expectation-first table');
      document.edit(opener.start,opener.start,'in ','expectation table introducer');
    }
  }
  return [...documents.values()].map(document => document.result());
}
