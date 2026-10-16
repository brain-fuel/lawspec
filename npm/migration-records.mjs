// Generated from templates/npm/migration-records.mjs by lawspec-dev generate. Do not edit.
// Local source constructors are identified by the compiler's declaration
// nodes. Imported/re-exported construction and native ABI conversion still
// require project-wide correspondence before any migration can be written.
export function planLegacyRecords(document,nodes) {
  const contains = (outer,inner) => outer.start<=inner.start && inner.end<=outer.end;
  const code = node => document.code(node.start,node.end);
  const replace = (token,content,reason) => {
    if (!token) throw new Error('Checked constructor has no token for '+reason);
    document.edit(token.start,token.end,content,reason);
  };
  const shapes = new Map();
  for (const type of nodes.filter(node=>node.kind==='declaration.type')) {
    if (nodes.some(node=>contains(type,node) && (node.kind==='type-equation' ||
        node.kind==='type-parameter-kind' && node.name!=='Type'))) continue;
    const constructors = nodes.filter(node=>node.kind==='constructor' && contains(type,node));
    const declared = constructors.map(constructor=>({...constructor,fields:nodes.filter(node=>node.kind==='constructor-field' && contains(constructor,node))}));
    if (!declared.some(constructor=>constructor.fields.length)) continue;
    const tokens = code(type);
    const nominal = declared.length===1 && declared[0].name===type.name;
    const delimiter = tokens.find(token=>token.text==='is');
    if (tokens[0]?.text!=='type' || !delimiter || tokens.at(-1)?.text!=='end')
      throw new Error('Checked payload declaration has no legacy delimiters');
    replace(delimiter,nominal?'is a record{':'is one of','payload type delimiter');
    replace(tokens.at(-1),'end type','type closer');
    for (const constructor of declared) {
      const fields = constructor.fields;
      const tag = code(constructor)[0];
      if (tag?.text!==constructor.name) throw new Error('Checked payload has no constructor token');
      const shape = {name:constructor.name,fields:fields.map(field=>field.name),record:nominal,wrap:nominal||fields.length>1};
      shapes.set(constructor.name,shape);
      if (nominal) {
        const preceding = tokens.filter(token=>token.end<=tag.start).at(-1);
        if (preceding?.text==='|') replace(preceding,'','nominal record alternative marker');
        replace(tag,'','nominal record constructor');
        const last = code(fields.at(-1)).at(-1);
        document.edit(last.end,last.end,'}','record type closer');
      } else if (fields.length===1) {
        const tokens = code(fields[0]);
        replace(tokens[0],'','single payload label');
        if (tokens[1]?.text==='::') replace(tokens[1],'of type','explicit payload annotation');
        else if (tokens[1]?.text!=='of' || tokens[2]?.text!=='type') throw new Error('Checked payload has no source annotation');
      } else if (fields.length>1) {
        document.edit(tag.end,tag.end,' of type record{','explicit record payload');
        const last = code(fields.at(-1)).at(-1);
        document.edit(last.end,last.end,'}','record payload closer');
      }
    }
  }
  const uniqueRanges = values => [...new Map(values.map(value=>[value.start+':'+value.end,value])).values()];
  const children = (parent,kind) => {
    const values = uniqueRanges(nodes.filter(node=>node.start>parent.start && contains(parent,node) && kind(node)));
    return values.filter(node=>!values.some(outer=>outer!==node && contains(outer,node)))
      .sort((left,right)=>left.start-right.start);
  };
  const wrap = (tag,arguments_,shape,reason) => {
    if (arguments_.length!==shape.fields.length) throw new Error('Checked constructor arguments do not match its source fields: '+shape.name);
    document.edit(tag.end,tag.end,' record{',reason+' opener');
    for (const [index,argument] of arguments_.entries()) {
      const tokens = code(argument);
      if (!tokens.length) throw new Error('Checked record argument has no source value');
      document.edit(tokens[0].start,tokens[0].start,(index?', ':'')+shape.fields[index]+' = ',reason+' field');
    }
    const last = code(arguments_.at(-1)).at(-1);
    document.edit(last.end,last.end,'}',reason+' closer');
  };
  // Parenthesized nodes repeat their child's constructor role. Only the node
  // whose physical opener is that constructor owns the inserted record; the
  // enclosing parentheses and annotations stay exactly where they were.
  const expressions = nodes.filter(node=>node.kind==='expression.constructor' && shapes.get(node.name)?.wrap && code(node)[0]?.text===node.name);
  for (const expression of expressions.filter(node=>!expressions.some(outer=>outer!==node && outer.start===node.start && outer.end>node.end))) {
    const shape = shapes.get(expression.name);
    const tag = code(expression)[0];
    if (tag?.text!==shape.name) throw new Error('Checked record construction has no source constructor');
    wrap(tag,children(expression,node=>node.kind.startsWith('expression.')),shape,'record construction');
  }
  for (const literal of nodes.filter(node=>node.kind==='literal' && shapes.get(node.name)?.wrap && code(node)[0]?.text===node.name)) {
    const shape = shapes.get(literal.name);
    const tag = code(literal)[0];
    if (tag?.text!==shape.name) throw new Error('Checked record literal has no source constructor');
    wrap(tag,children(literal,node=>node.kind==='literal'),shape,'record literal');
  }
  for (const branch of nodes.filter(node=>node.kind==='case-branch' && shapes.get(node.name)?.wrap)) {
    const shape = shapes.get(branch.name);
    const tokens = code(branch);
    const arrow = tokens.find(token=>token.text==='->');
    const tag = nodes.find(node=>node.kind==='pattern-constructor' && contains(branch,node) && node.name===shape.name && node.end<=arrow?.start);
    const bindings = nodes.filter(node=>node.kind==='pattern-binding' && contains(branch,node) && node.end<=arrow?.start);
    if (!tag || !arrow) throw new Error('Checked record pattern has no source branch');
    wrap(code(tag)[0],bindings,shape,'record pattern');
  }
}
