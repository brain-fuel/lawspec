// Generated from templates/npm/migration-records.mjs by lawspec-dev generate. Do not edit.
// Declarations supply shapes; the checked resolver supplies identities across
// imports and re-exports. No client-side import resolver is used here.
const contains = (outer,inner) => outer.start<=inner.start && inner.end<=outer.end;
function declarations(nodes) {
  return nodes.filter(node=>node.kind==='declaration.type').flatMap(type=>{
    if (nodes.some(node=>contains(type,node) && (node.kind==='type-equation' ||
        node.kind==='type-parameter-kind' && node.name!=='Type'))) return [];
    const constructors=nodes.filter(node=>node.kind==='constructor' && contains(type,node));
    const declared=constructors.map(constructor=>({...constructor,fields:nodes.filter(node=>node.kind==='constructor-field' && contains(constructor,node))}));
    return declared.some(constructor=>constructor.fields.length) ? [{type,declared,nominal:declared.length===1 && declared[0].name===type.name}] : [];
  });
}
export function legacyRecordShapes(sources) {
  const shapes=new Map();
  for (const source of sources) {
    if (!Array.isArray(source.bindings)) throw new Error('Record migration requires checked namespace bindings');
    for (const {declared,nominal} of declarations(source.nodes)) for (const constructor of declared) {
      const binding=source.bindings.find(binding=>binding.namespace==='constructor' && binding.name===constructor.name);
      if (!binding) throw new Error('Checked constructor has no resolver identity: '+constructor.name);
      if (shapes.has(binding.target)) throw new Error('Duplicate checked constructor identity: '+binding.target);
      shapes.set(binding.target,{name:constructor.name,fields:constructor.fields.map(field=>field.name),record:nominal,wrap:nominal||constructor.fields.length>1});
    }
  }
  return shapes;
}
export function planLegacyRecords(document,source,shapes) {
  const nodes=source.nodes;
  const contains = (outer,inner) => outer.start<=inner.start && inner.end<=outer.end;
  const code = node => document.code(node.start,node.end);
  const replace = (token,content,reason) => {
    if (!token) throw new Error('Checked constructor has no token for '+reason);
    document.edit(token.start,token.end,content,reason);
  };
  const shapeOf = name => shapes.get(source.bindings.find(binding=>binding.namespace==='constructor' && binding.name===name)?.target);
  const sourceTag = node => {
    if (!node?.name) return null;
    const tokens=code(node),count=node.name.split('.').length*2-1;
    return tokens.slice(0,count).map(token=>token.text).join('')===node.name
      ? {start:tokens[0].start,end:tokens[count-1].end} : null;
  };
  for (const {type,declared,nominal} of declarations(nodes)) {
    const tokens = code(type);
    const delimiter = tokens.find(token=>token.text==='is');
    if (tokens[0]?.text!=='type' || !delimiter || tokens.at(-1)?.text!=='end')
      throw new Error('Checked payload declaration has no legacy delimiters');
    replace(delimiter,nominal?'is a record{':'is one of','payload type delimiter');
    replace(tokens.at(-1),'end type','type closer');
    for (const constructor of declared) {
      const fields = constructor.fields;
      const tag = code(constructor)[0];
      if (tag?.text!==constructor.name) throw new Error('Checked payload has no constructor token');
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
  const expressions = nodes.filter(node=>node.kind==='application.constructor' && shapeOf(node.name)?.wrap && sourceTag(node));
  for (const expression of expressions.filter(node=>!expressions.some(outer=>outer!==node && outer.start===node.start && outer.end>node.end))) {
    const shape = shapeOf(expression.name);
    const tag = sourceTag(expression);
    wrap(tag,children(expression,node=>node.kind.startsWith('expression.') || node.kind==='application' || node.kind==='application.constructor'),shape,'record construction');
  }
  for (const literal of nodes.filter(node=>node.kind==='literal' && shapeOf(node.name)?.wrap && sourceTag(node))) {
    const shape = shapeOf(literal.name);
    const tag = sourceTag(literal);
    wrap(tag,children(literal,node=>node.kind==='literal'),shape,'record literal');
  }
  for (const branch of nodes.filter(node=>node.kind==='case-branch' && shapeOf(node.name)?.wrap)) {
    const shape = shapeOf(branch.name);
    const tokens = code(branch);
    const arrow = tokens.find(token=>token.text==='->');
    const tag = nodes.find(node=>node.kind==='pattern-constructor' && contains(branch,node) && node.name===branch.name && node.end<=arrow?.start);
    const bindings = nodes.filter(node=>node.kind==='pattern-binding' && contains(branch,node) && node.end<=arrow?.start);
    if (!tag || !arrow) throw new Error('Checked record pattern has no source branch');
    wrap(sourceTag(tag),bindings,shape,'record pattern');
  }
}
