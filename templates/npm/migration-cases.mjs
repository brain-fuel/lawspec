// Selection edits use actual case/branch ranges, including nested selections
// in the selected expression. No contextual identifier is treated as a block.
export function planLegacyCases(document,nodes) {
  const contains = (outer,inner) => outer.start <= inner.start && inner.end <= outer.end;
  const replace = (token,content,reason) => {
    if (!token) throw new Error('Checked case has no token for '+reason);
    document.edit(token.start,token.end,content,reason);
  };
  const cases = nodes.filter(node=>node.kind==='case');
  for (const selected of cases) {
    const branches = nodes.filter(node=>node.kind==='case-branch' && contains(selected,node) &&
      !cases.some(inner=>inner!==selected && contains(selected,inner) && contains(inner,node)));
    if (!branches.length) throw new Error('Checked case has no source branches');
    const tokens = document.code(selected.start,selected.end);
    const prefix = document.code(selected.start,Math.min(...branches.map(branch=>branch.start)));
    if (tokens[0]?.text!=='match' || prefix.at(-1)?.text!=='with' || tokens.at(-1)?.text!=='end')
      throw new Error('Checked case has no legacy delimiters');
    replace(tokens[0],'first matching case of','case opener');
    replace(prefix.at(-1),':','case delimiter');
    replace(tokens.at(-1),'end case','case closer');
    for (const branch of branches) {
      const tokens = document.code(branch.start,branch.end);
      const arrow = tokens.find(token=>token.text==='->');
      if (tokens[0]?.text!=='|' || !arrow) throw new Error('Checked case branch has no legacy delimiters');
      if (nodes.some(node=>node.kind==='expression.name' && node.name==='it' &&
          node.start>=arrow.end && contains(branch,node)))
        throw new Error('A legacy case branch referring to it needs an explicit rename before introducing scoped it');
      replace(tokens[0],'when','case branch');
      replace(arrow,'then','case branch delimiter');
    }
  }
  // Payload-free alternatives need no ABI or field correspondence change.
  // Payload-bearing and indexed declarations remain separate migration work.
  for (const type of nodes.filter(node=>node.kind==='declaration.type')) {
    if (nodes.some(node=>['constructor-field','type-equation','type-parameter'].includes(node.kind) && contains(type,node))) continue;
    const tokens = document.code(type.start,type.end);
    const delimiter = tokens.find(token=>token.text==='is');
    if (tokens[0]?.text!=='type' || !delimiter || tokens.at(-1)?.text!=='end')
      throw new Error('Checked alternative type has no legacy delimiters');
    replace(delimiter,'is one of','alternative type delimiter');
    replace(tokens.at(-1),'end type','type closer');
  }
}
