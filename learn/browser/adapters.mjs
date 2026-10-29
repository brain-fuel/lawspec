const commonName = /^[A-Za-z_][A-Za-z0-9_]*$/;
const reserved = new Set([
  'abstract',
  'and',
  'as',
  'assert',
  'base',
  'begin',
  'class',
  'default',
  'delegate',
  'do',
  'done',
  'downcast',
  'downto',
  'elif',
  'else',
  'end',
  'exception',
  'extern',
  'false',
  'finally',
  'fixed',
  'for',
  'fun',
  'function',
  'global',
  'if',
  'in',
  'inherit',
  'inline',
  'interface',
  'internal',
  'lazy',
  'let',
  'match',
  'member',
  'module',
  'mutable',
  'namespace',
  'new',
  'null',
  'of',
  'open',
  'or',
  'override',
  'private',
  'public',
  'rec',
  'return',
  'sig',
  'static',
  'struct',
  'then',
  'to',
  'true',
  'try',
  'type',
  'upcast',
  'use',
  'val',
  'void',
  'when',
  'while',
  'with',
  'yield',
]);
function shape(type)
{
  if (
    type?.kind === 'constructor' &&
    type.name === 'Bool' &&
    type.arguments.length === 0
  )
  {
    return 'boolean';
  }
  if (
    type?.kind === 'constructor' &&
    type.name === 'Int32' &&
    type.arguments.length === 0
  )
  {
    return 'integer';
  }
  if (
    type?.kind === 'constructor' &&
    type.name === 'List' &&
    type.arguments.length === 1 &&
    type.arguments[0].kind === 'type' &&
    shape(type.arguments[0].type) === 'integer'
  )
  {
    return 'list';
  }
  throw new Error(
    'Unsupported browser adapter type: ' +
      JSON.stringify(type) +
      '. The preview supports Int32, Bool and List Int32.',
  );
}
/** Derive the implementation boundary from checked declarations, excluding functions whose definitions LawSpec already provides. ref:DEC-learn-generated-boundaries */
export function implementationBinding(checked, sourcePaths)
{
  const defined = new Set((checked.definitions ?? []).map(row => row.id));
  const candidates = (checked.units ?? [])
    .flatMap(unit =>
      unit.declarations.map(declaration => ({unit: unit.id, declaration})),
    )
    .filter(
      ({declaration}) =>
        declaration.origin?.kind === 'source' &&
        (sourcePaths ?? ['Tests.lawspec']).includes(
          declaration.origin.span?.start.file,
        ) &&
        !defined.has(declaration.id),
    );
  if (candidates.length !== 1)
  {
    throw new Error(
      `Unsupported browser adapter project: expected one implementation declaration, found ${candidates.length}.`,
    );
  }
  const {unit, declaration} = candidates[0];
  if (!commonName.test(declaration.name) || reserved.has(declaration.name))
  {
    throw new Error(
      'Unsupported cross-language implementation name: ' + declaration.name,
    );
  }
  let result = declaration.type;
  const inputs = [];
  while (result.kind === 'function')
  {
    inputs.push(shape(result.parameter));
    result = result.result;
  }
  if (inputs.includes('boolean'))
  {
    throw new Error(
      'Unsupported browser generator input: Bool; Boolean results are supported.',
    );
  }
  if (
    !inputs.length ||
    inputs.length > 8 ||
    (inputs.length > 1 && inputs.some(value => value !== 'integer'))
  )
  {
    throw new Error(
      'Unsupported browser adapter signature: multiple inputs must be Int32.',
    );
  }
  return {
    declaration: declaration.id,
    unit,
    name: declaration.name,
    inputs,
    input: inputs.length > 1 ? 'tuple' : inputs[0],
    output: shape(result),
    checkedType: declaration.type,
  };
}
/** Emit the F# bridge from the checked input/result shapes; Fable checks the bridge together with learner code. ref:DEC-learn-generated-boundaries */
export function fsharpAdapter(binding)
{
  const inputs = binding.inputs ?? [binding.input];
  const inputType =
    inputs.length > 1 || binding.input === 'list' ? 'int array' : 'int';
  const arguments_ =
    inputs.length > 1
      ? inputs.map((_, i) => `input[${i}]`).join(' ')
      : binding.input === 'list'
        ? '(Array.toList input)'
        : 'input';
  const resultType =
    binding.output === 'list'
      ? 'int array'
      : binding.output === 'boolean'
        ? 'bool'
        : 'int';
  return `module Adapter\nlet call (input: ${inputType}) : ${resultType} = Solution.${binding.name} ${arguments_}${binding.output === 'list' ? ' |> List.toArray' : ''}\n`;
}
/** Emit the typed implementation boundary only; every assertion comes from generated LawSpec tests. ref:DEC-learn-tests-in-lawspec */
export function adapterSource(binding, language)
{
  const raw =
    language === 'fsharp'
      ? 'Adapter.js'
      : `Solution.${language === 'typescript' ? 'ts' : 'js'}`;
  const inputs = binding.inputs ?? [binding.input];
  const convert = value =>
    value === 'integer' ? 'integer' : value === 'boolean' ? 'boolean' : 'list';
  const validateInput =
    inputs.length > 1 ? 'tuple(input)' : `${convert(binding.input)}(input)`;
  const args =
    inputs.length > 1
      ? inputs.map((value, i) => `${convert(value)}(input[${i}])`).join(', ')
      : `${convert(binding.input)}(input)`;
  const invoke =
    language === 'fsharp'
      ? `solution.call(input)`
      : `solution.${binding.name}(${args})`;
  return `import * as solution from './${raw}';
const integer=x=>{if(!Number.isInteger(x)||x< -2147483648||x>2147483647)throw new TypeError('Adapter expects Int32');return x;};
const boolean=x=>{if(typeof x!=='boolean')throw new TypeError('Adapter expects Bool');return x;};
const list=xs=>{if(!Array.isArray(xs))throw new TypeError('Adapter expects an integer list');return xs.map(integer);};
const tuple=xs=>{if(!Array.isArray(xs)||xs.length!==${inputs.length})throw new TypeError('Adapter expects ${inputs.length} arguments');return xs.map(integer);};
export const call=input=>{input=${validateInput};const output=${convert(binding.output)}(${invoke});globalThis.__lessonObserveCall?.(input,output);return output;};
${inputs.length > 1 ? `export const ${binding.name}=(...inputs)=>call(inputs);` : `export {call as ${binding.name}};`}`;
}
/** Use the compiler's actual user-owned module path when wiring generated tests to the checked implementation. ref:DEC-learn-generated-boundaries */
export function harnessModule(plan, binding)
{
  const expected = 'src/' + binding.unit.split('.').join('/') + '.mjs';
  const files = plan.files.filter(
    file => file.placement === 'source' && file.path === expected,
  );
  if (files.length !== 1)
  {
    throw new Error(
      `Unsupported browser module graph: expected one native implementation module, found ${files.length}.`,
    );
  }
  return files[0].path;
}
