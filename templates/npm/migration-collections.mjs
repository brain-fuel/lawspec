// Names are changed only after the existing compiler has resolved their
// namespace or free-reference identity. Lexical bindings are never guessed.
const orderedSet='lawspec.collections::type::Set';
const operations=new Map(['Of','Member','Insert','Remove','Union','Intersection','Difference']
  .map(suffix=>['lawspec.collections::set'+suffix,'sortedSet'+suffix]));

export function planLegacyCollectionNames(document,source) {
  const {nodes,bindings,references}=source;
  if (!Array.isArray(bindings)||!Array.isArray(references))
    throw new Error('Collection migration requires checked namespaces and free references');
  const contains=(outer,inner)=>outer.start<=inner.start&&inner.end<=outer.end;
  const lookup=(namespace,name)=>bindings.find(binding=>binding.namespace===namespace&&binding.name===name);
  const rename=(range,name,replacement,reason)=>{
    const tokens=document.code(range.start,range.end);
    if (tokens.map(token=>token.text).join('')!==name)
      throw new Error('Checked name does not match its original source tokens: '+name);
    const last=tokens.at(-1);
    document.edit(last.start,last.end,replacement,reason);
  };
  for (const node of nodes.filter(node=>node.kind==='type-name')) {
    if (node.name==='BigUInt' && !lookup('type',node.name) && !lookup('refinement',node.name))
      rename(node,node.name,'Whole','exact unsigned type name');
    if (lookup('type',node.name)?.target===orderedSet) {
      if (lookup('refinement',node.name)) throw new Error('A collection type and refinement share a source spelling: '+node.name);
      rename(node,node.name,'SortedSet','ordered set type name');
    }
  }
  for (const reference of references) {
    const replacement=operations.get(reference.declaration);
    if (!replacement) continue;
    const range=document.range({kind:'source',span:reference.span});
    if (!range) throw new Error('Checked collection reference belongs to another source');
    rename(range,reference.name,replacement,'ordered set operation');
  }
  for (const item of nodes.filter(node=>['import-item','export-item'].includes(node.kind))) {
    if (item.name.startsWith('`')) continue;
    let name=item.name;
    if (item.kind==='import-item') {
      const parent=nodes.find(node=>node.kind==='import'&&contains(node,item));
      const alias=parent&&nodes.find(node=>node.kind==='import-alias'&&node.start===parent.start&&node.end===parent.end);
      if (!alias) throw new Error('Checked import item has no parsed alias');
      name=alias.name+'.'+name;
    }
    const type=lookup('type',name),value=lookup('value',name);
    const replacement=type?.target===orderedSet?'SortedSet':operations.get(value?.declaration);
    if (replacement) rename(item,item.name,replacement,'ordered set import or export');
  }
}
