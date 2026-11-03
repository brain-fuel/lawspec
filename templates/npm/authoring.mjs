// Bounded native syntax checks use upstream Tree-sitter grammars. Findings are
// review candidates, not proof of semantic or nominal equivalence.
// ref:DEC-authoring-advisories
import {readFile, readdir} from 'node:fs/promises';
import {createHash} from 'node:crypto';
import path from 'node:path';
import {programTargets, artifactTargets} from './templates.mjs';

const extensions = {
  '.java': 'java',
  '.py': 'python',
  '.js': 'javascript',
  '.mjs': 'javascript',
  '.cjs': 'javascript',
  '.ts': 'typescript',
  '.mts': 'typescript',
  '.cts': 'typescript',
  '.tsx': 'tsx',
  '.jsx': 'javascript',
  '.go': 'go',
  '.hs': 'haskell',
  '.lhs': 'literate-haskell',
  '.kt': 'kotlin',
  '.kts': 'kotlin',
  '.rs': 'rust',
  '.erl': 'erlang',
  '.hrl': 'erlang',
  '.ex': 'elixir',
  '.exs': 'elixir',
  '.gleam': 'gleam',
  '.fs': 'fsharp',
  '.fsx': 'fsharp',
  '.fsi': 'fsharp',
  '.cs': 'csharp',
  '.scala': 'scala',
  '.groovy': 'groovy',
  '.clj': 'clojure',
  '.cljc': 'clojure',
  '.swift': 'swift',
  '.pl': 'prolog',
};
// Composite targets analyze their emitted host language as well.
const hostLanguages = {
  javascript: ['javascript', 'typescript', 'tsx'],
  typescript: ['typescript', 'javascript', 'tsx'],
  haskell: ['haskell', 'literate-haskell'],
  kotlin: ['kotlin', 'java'],
  scala: ['scala', 'java'],
  groovy: ['groovy', 'java'],
  clojure: ['clojure', 'java'],
  elixir: ['elixir', 'erlang'],
  gleam: ['gleam', 'erlang'],
  csharp: ['csharp', 'fsharp'],
  prolog: ['prolog', 'python'],
};
const declarations = {
  java: [
    'class_declaration',
    'record_declaration',
    'interface_declaration',
    'enum_declaration',
    'method_declaration',
  ],
  python: ['class_definition', 'function_definition'],
  javascript: [
    'class_declaration',
    'function_declaration',
    'variable_declarator',
  ],
  typescript: [
    'class_declaration',
    'function_declaration',
    'interface_declaration',
    'type_alias_declaration',
    'enum_declaration',
    'variable_declarator',
  ],
  go: ['type_spec', 'function_declaration', 'method_declaration'],
  haskell: ['data_type', 'newtype', 'type_synomym', 'function', 'bind'],
  kotlin: [
    'class_declaration',
    'object_declaration',
    'function_declaration',
    'type_alias',
  ],
  rust: ['struct_item', 'enum_item', 'type_item', 'function_item'],
  erlang: ['record_decl', 'type_alias', 'fun_decl'],
  elixir: ['call'],
  gleam: ['type_definition', 'type_alias', 'function'],
  fsharp: ['type_definition', 'function_or_value_defn'],
  csharp: [
    'class_declaration',
    'record_declaration',
    'struct_declaration',
    'interface_declaration',
    'enum_declaration',
    'method_declaration',
  ],
  scala: [
    'class_definition',
    'object_definition',
    'trait_definition',
    'enum_definition',
    'type_definition',
    'function_definition',
  ],
  groovy: [
    'class_declaration',
    'method_declaration',
    'interface_declaration',
    'enum_declaration',
  ],
  clojure: ['list_lit'],
  swift: [
    'class_declaration',
    'protocol_declaration',
    'typealias_declaration',
    'function_declaration',
  ],
  prolog: ['clause', 'dict'],
};
const digest = content => createHash('sha256').update(content).digest('hex');
const comment = node => /comment|xml_doc/.test(node.type);
let runtime;
const languages = new Map();
const syntaxCache = new Map();
async function languageFor(language)
{
  runtime ??= (async () =>
  {
    const module = await import('web-tree-sitter');
    await module.Parser.init();
    const lock = JSON.parse(
      await readFile(
        new URL('./native-parsers/lock.json', import.meta.url),
        'utf8',
      ),
    );
    if (programTargets.some(target => !lock.grammars[target]))
      throw new Error('Parser coverage differs from programTargets');
    return {...module, lock};
  })();
  const api = await runtime;
  if (!languages.has(language))
  {
    const entry = api.lock.grammars[language];
    if (!entry) throw new Error(`No bundled parser for ${language}`);
    const bytes = await readFile(
      new URL('./native-parsers/' + entry.file, import.meta.url),
    );
    if (digest(bytes) !== entry.sha256)
      throw new Error(`Parser digest mismatch for ${language}`);
    languages.set(language, await api.Language.load(bytes));
  }
  return {Parser: api.Parser, language: languages.get(language)};
}
function nameNode(node, language)
{
  if (language === 'prolog')
  {
    let term = node.childForFieldName('term') ?? node;
    if (term.type === 'binary_operation') term = term.childForFieldName('left');
    return term?.childForFieldName('functor') ?? term?.childForFieldName('tag');
  }
  if (language === 'clojure')
  {
    const children = node.namedChildren;
    return ['defrecord', 'deftype', 'defn', 'defn-'].includes(children[0]?.text)
      ? children[1]
      : null;
  }
  if (language === 'elixir')
  {
    const head = node.childForFieldName('target')?.text;
    if (!['defmodule', 'def', 'defp'].includes(head)) return null;
    const args = node.namedChildren.find(child => child.type === 'arguments');
    const first = args?.namedChildren[0];
    return first?.childForFieldName('target') ?? first;
  }
  if (language === 'erlang' && node.type === 'fun_decl')
    return node.childForFieldName('clause')?.childForFieldName('name');
  let found =
    node.childForFieldName('name') ?? node.childForFieldName('type_name');
  if (found) return found;
  const pending = [...node.namedChildren];
  while (pending.length)
  {
    const child = pending.shift();
    if (
      /^(identifier|type_identifier|name|simple_identifier|type_name|atom|variable)$/.test(
        child.type,
      )
    )
      return child;
    if (
      /^(type_name|record_type_defn|union_type_defn|function_declaration_left|function_or_value_defn|function_declaration|function_head|value_declaration_left|identifier_pattern|long_identifier_or_op|long_identifier|type|head)$/.test(
        child.type,
      )
    )
      pending.unshift(...child.namedChildren);
  }
  return null;
}
function leaves(node)
{
  if (comment(node)) return [];
  if (!node.childCount) return [[node.type, node.text]];
  return node.children.flatMap(leaves);
}
async function parse(source)
{
  const language = extensions[path.extname(source.path)];
  if (!language)
    return {
      status: 'unsupported',
      reason: 'No grammar selected for this file extension',
      declarations: [],
    };
  if (Buffer.byteLength(source.content) > 2 * 1024 * 1024)
    return {
      status: 'incomplete',
      reason: 'Native file exceeds the 2 MiB analysis limit',
      declarations: [],
    };
  const key = language + ':' + digest(source.content);
  if (syntaxCache.has(key)) return syntaxCache.get(key);
  let parser, tree;
  try
  {
    const api = await languageFor(language);
    parser = new api.Parser();
    parser.setLanguage(api.language);
    tree = parser.parse(source.content);
    if (!tree || tree.rootNode.hasError)
      return {
        status: 'incomplete',
        reason: 'Tree-sitter reported an ERROR or missing node',
        declarations: [],
      };
    const result = [];
    const imports = [];
    const modules = [];
    const limits = [];
    const stack = [tree.rootNode];
    let count = 0;
    while (stack.length)
    {
      const node = stack.pop();
      if (++count > 100000)
        return {
          status: 'incomplete',
          reason: 'Native syntax exceeds the 100000-node analysis limit',
          declarations: [],
        };
      stack.push(...node.namedChildren);
      if (
        /^(macro_invocation|macro_definition|preproc_call|preproc_if|preproc_ifdef)$/.test(
          node.type,
        ) &&
        !(
          language === 'rust' &&
          node.type === 'macro_invocation' &&
          ['unimplemented', 'todo', 'panic'].includes(
            node.childForFieldName('macro')?.text,
          ) &&
          node.namedChildren
            .filter(child => child.type === 'token_tree')
            .every(tokens =>
              tokens.namedChildren.every(
                child => child.type === 'string_literal',
              ),
            )
        )
      )
        limits.push(
          `Unsupported ${node.type} at line ${node.startPosition.row + 1}`,
        );
      if (
        /^(import_statement|import_from_statement|import_declaration|import_spec|import_header|use_declaration|open_declaration|open_statement|import)$/.test(
          node.type,
        )
      )
      {
        let module =
          node.childForFieldName('source') ??
          node.childForFieldName('module_name') ??
          node.childForFieldName('module') ??
          node.childForFieldName('path') ??
          node.childForFieldName('argument') ??
          node.childForFieldName('name') ??
          node.namedChildren.find(child =>
            /string|identifier|name|module/.test(child.type),
          );
        if (module?.type === 'aliased_import')
          module = module.childForFieldName('name');
        if (module) imports.push(module.text.replace(/^['"]|['"]$/g, ''));
        else
          limits.push(
            `Unresolved import syntax at line ${node.startPosition.row + 1}`,
          );
      }
      if (
        /^(namespace_declaration|file_scoped_namespace_declaration|package_declaration|package_clause|named_module|module_attribute|header)$/.test(
          node.type,
        )
      )
      {
        const module =
          node.childForFieldName('name') ??
          node.childForFieldName('module') ??
          node.namedChildren.find(child => /identifier|name/.test(child.type));
        if (module) modules.push(module.text);
      }
      if (language === 'clojure' && node.type === 'list_lit')
      {
        const children = node.namedChildren,
          head = children[0]?.text;
        if (head === 'ns' && children[1]) modules.push(children[1].text);
        if ([':require', ':use'].includes(head))
          for (const entry of children.slice(1))
          {
            if (
              entry.type === 'vec_lit' &&
              entry.namedChildren[0]?.type === 'sym_lit'
            )
              imports.push(entry.namedChildren[0].text);
            else limits.push('Unsupported Clojure namespace reference');
          }
        if (
          ['defmacro', 'load', 'load-file', 'require', 'use', 'eval'].includes(
            head,
          )
        )
          limits.push(`Dynamic Clojure declaration or reference: ${head}`);
      }
      if (language === 'elixir' && node.type === 'call')
      {
        const head = node.childForFieldName('target')?.text;
        if (['alias', 'import', 'require', 'use'].includes(head))
        {
          const module = node.namedChildren.find(
            child => child.type === 'arguments',
          )?.namedChildren[0];
          if (module?.type === 'alias') imports.push(module.text);
          else limits.push(`Unsupported Elixir ${head} reference`);
          if (head === 'use')
            limits.push('Elixir use may introduce declarations through macros');
        }
        if (head === 'defmacro' || head === 'defmacrop')
          limits.push('Elixir macro declaration requires expansion');
      }
      if (
        language === 'prolog' &&
        node.type === 'compound_term' &&
        ['use_module', 'ensure_loaded', 'include', 'reexport'].includes(
          node.childForFieldName('functor')?.text,
        )
      )
      {
        const module = node.childrenForFieldName('argument')[0];
        if (module) imports.push(module.text.replace(/^'|'$/g, ''));
        else limits.push('Unsupported Prolog module reference');
      }
      if (
        language === 'erlang' &&
        /^(import_attribute|include|include_lib)$/.test(node.type)
      )
      {
        const module =
          node.childForFieldName('module') ??
          node.childForFieldName('file') ??
          node.namedChildren[0];
        if (module) imports.push(module.text.replace(/^"|"$/g, ''));
        else limits.push('Unsupported Erlang module reference');
      }
      if (!declarations[language].includes(node.type)) continue;
      const name = nameNode(node, language);
      if (!name) continue;
      const tokens = leaves(node);
      result.push({
        name: name.text,
        kind: node.type,
        line: node.startPosition.row + 1,
        fields:
          language === 'prolog' && node.type === 'dict'
            ? node.namedChildren
                .filter(child => child.type === 'dict_pair')
                .map(child => child.childForFieldName('key')?.text)
                .filter(Boolean)
                .sort()
            : [],
        identifiers: tokens
          .filter(([type]) =>
            /identifier|atom|symbol|name|constructor|variable|alias/.test(type),
          )
          .map(([type, text]) =>
            language === 'clojure'
              ? text.replace(/\.$/, '')
              : /atom/.test(type)
                ? text.replace(/^'|'$/g, '')
                : text,
          ),
        model:
          /class|record|struct|enum|interface|type|newtype|dict/.test(
            node.type,
          ) ||
          (language === 'elixir' &&
            node.childForFieldName('target')?.text === 'defmodule') ||
          (language === 'clojure' &&
            ['defrecord', 'deftype'].includes(node.namedChildren[0]?.text)),
        fingerprint: digest(
          JSON.stringify(
            tokens.map(([type, text]) => [
              type,
              text === name.text ? '$declaration' : text,
            ]),
          ),
        ),
      });
    }
    const parsed = {
      status: 'complete',
      declarations: result,
      imports,
      modules,
      limits,
      fingerprint: digest(JSON.stringify(leaves(tree.rootNode))),
    };
    // Bound process-local memory; cached summaries contain no parser nodes.
    if (syntaxCache.size >= 128) syntaxCache.clear();
    syntaxCache.set(key, parsed);
    return parsed;
  }
  catch (error)
  {
    return {status: 'incomplete', reason: error.message, declarations: []};
  }
  finally
  {
    tree?.delete();
    parser?.delete();
  }
}
const rules = [
  'copied-generated',
  'native-model',
  'adapter-identity',
  'manual-conversion',
];
export function settleAdvice(advice, exceptions = [])
{
  if (
    !Array.isArray(exceptions) ||
    exceptions.some(
      e =>
        !e ||
        typeof e.declaration !== 'string' ||
        !e.declaration.trim() ||
        typeof e.reason !== 'string' ||
        !e.reason.trim() ||
        typeof e.rule !== 'string' ||
        !e.rule.trim(),
    )
  )
    throw new Error(
      'Authoring exceptions require a declaration, rule and nonempty reason',
    );
  const findings = advice.findings.map(finding =>
  {
    const exception = exceptions.find(
      e => e.declaration === finding.declaration && e.rule === finding.rule,
    );
    return exception
      ? {...finding, status: 'excepted', reason: exception.reason}
      : finding;
  });
  return {
    ...advice,
    findings,
    ok:
      !findings.some(f => f.status === 'unresolved') &&
      advice.checks.every(c =>
        ['complete', 'not-applicable'].includes(c.status),
      ),
  };
}
export async function advise(call, input)
{
  const {nativeSources, exceptions, strict, ...request} = input;
  const result = await call({
    schemaVersion: 5,
    ...request,
    advice: true,
    method: request.target ? 'inspect' : 'advise',
  });
  if (result.diagnostics?.length) return result;
  const report = result.advice ?? {findings: [], checks: []};
  if (request.target)
  {
    const native = await analyzeNative(result, request, nativeSources);
    report.findings.push(...native.findings);
    report.checks.push(...native.checks);
  }
  result.advice = settleAdvice(report, exceptions);
  // Required interfaces remain inspect's output; advise returns findings only.
  delete result.interface;
  delete result.files;
  return result;
}
export async function analyzeNative(result, input, sources)
{
  const target = input.target;
  const checks = [];
  const findings = [];
  const check = (status, reason) =>
  {
    for (const rule of rules)
      checks.push({
        rule,
        target,
        status,
        ...(reason ? {reason} : {}),
        scope: 'declared native syntax; no whole-program type equivalence',
      });
  };
  if (artifactTargets.includes(target))
  {
    check('not-applicable', 'Artifact target has no native application model');
    return {findings, checks};
  }
  if (!programTargets.includes(target))
  {
    check('unsupported', 'Unknown program target');
    return {findings, checks};
  }
  if (!Array.isArray(sources))
  {
    check('incomplete', 'Native sources were not supplied');
    return {findings, checks};
  }
  const invalid = sources.filter(
    source =>
      !source ||
      typeof source.path !== 'string' ||
      typeof source.content !== 'string',
  );
  if (invalid.length)
  {
    check('incomplete', 'Malformed native source');
    return {findings, checks};
  }
  const generated = (result.files ?? []).filter(
    f => f.ownership === 'generated' && extensions[path.extname(f.path)],
  );
  const expected = new Map((result.files ?? []).map(f => [f.path, f]));
  const acceptedDigests = new Map(
    (result.interface?.generatedDigests ?? []).map(file => [
      file.path,
      new Set(file.sha256),
    ]),
  );
  const rawCopies = new Map(generated.map(f => [digest(f.content), f.path]));
  for (const [file, digests] of acceptedDigests)
    for (const hash of digests) rawCopies.set(hash, file);
  const baselines = new Map();
  const names = new Set();
  const adapterNames = new Set();
  const boundTypes = input.nativeBindings?.types ?? [];
  const recordShapes = (result.dataTypes ?? [])
    .filter(type => type.constructors.length === 1)
    .map(type => type.constructors[0].fields.map(field => field.name).sort());
  const observedBindings = new Set();
  const boundName = (source, declaration, parsed) =>
    boundTypes.some(binding =>
    {
      const references = [
        binding.native,
        ...(binding.constructors ?? []).map(c => c.native),
      ].filter(Array.isArray);
      const matched = references.some(ref =>
      {
        const name = ref.at(-1),
          module = ref
            .slice(0, -1)
            .filter(part => part !== 'crate')
            .join('/');
        const file = source.path.replace(/\.[^.]+$/, '');
        const declaredModules = (parsed.modules ?? []).map(value =>
          value.replace(/\.|::/g, '/'),
        );
        return (
          (ref.length > 1 && ref.join('.') === declaration.name) ||
          (name === declaration.name &&
            module &&
            (file === module ||
              file.endsWith('/' + module) ||
              file.endsWith('/' + module + '/' + name) ||
              file === module + '/' + name ||
              declaredModules.includes(module)))
        );
      });
      if (matched) observedBindings.add(binding.type);
      return matched;
    });
  let incomplete = false;
  const relevant = (result.files ?? []).filter(
    f =>
      extensions[path.extname(f.path)] &&
      (f.ownership === 'user' ||
        (/data|types|schema/i.test(f.path) &&
          !/runtime|testing/i.test(f.path))),
  );
  for (const file of relevant)
  {
    const parsed = await parse(file);
    if (parsed.status !== 'complete')
    {
      incomplete = true;
      checks.push({
        rule: 'native-baseline',
        target,
        path: file.path,
        status: parsed.status,
        reason: parsed.reason,
      });
      continue;
    }
    for (const declaration of parsed.declarations)
    {
      if (file.ownership === 'user')
      {
        if (!declaration.model) adapterNames.add(declaration.name);
        continue;
      }
      if (declaration.model) names.add(declaration.name);
      baselines.set(declaration.fingerprint, {...declaration, path: file.path});
    }
  }
  for (const item of result.interface?.data ?? [])
  {
    if (item.ownership === 'bound') continue;
    if (item.nativeName) names.add(item.nativeName);
    for (const c of item.constructors ?? [])
      if (c.allocatedName) names.add(c.allocatedName);
  }
  const modulePaths = [...(result.files ?? []), ...sources].map(file =>
    file.path
      .replace(/\.[^.]+$/, '')
      .split(path.sep)
      .join('/'),
  );
  const standard =
    /^(builtins$|node:|java\.|javax\.|scala\.|kotlin\.|System(?:\.|$)|Microsoft\.|std(?:::|\.|$)|core::|alloc::|Data\.|Control\.|GHC\.|Prelude$|typing$|dataclasses$|functools$|fractions$|decimal$|math$|collections$|abc$|sys$|os$|pathlib$|typing_extensions$|gleam\/|erlang$|Elixir\.|clojure\.|library\()/;
  const add = (rule, source, declaration, message) =>
    findings.push({
      rule,
      target,
      path: source.path,
      declaration: `${source.path}::${declaration.name}`,
      line: declaration.line,
      severity: 'warning',
      status: 'unresolved',
      message,
      suggestion:
        'Migrate to the generated interface; retain an application model through explicit checked bindings/codecs, or a declaration-scoped exception with a reason.',
    });
  for (const source of sources)
  {
    if (typeof source.path !== 'string' || typeof source.content !== 'string')
    {
      incomplete = true;
      checks.push({
        rule: 'native-source',
        target,
        status: 'incomplete',
        reason: 'Malformed native source',
      });
      continue;
    }
    const language = extensions[path.extname(source.path)];
    if (language && !(hostLanguages[target] ?? [target]).includes(language))
    {
      checks.push({
        rule: 'native-language',
        target,
        path: source.path,
        status: 'not-applicable',
        reason: `${language} is outside the selected target's native languages`,
      });
      continue;
    }
    const known = expected.get(source.path);
    if (known?.ownership === 'generated')
    {
      if (
        known.content !== source.content &&
        !acceptedDigests.get(source.path)?.has(digest(source.content))
      )
      {
        const original = await parse(known),
          actual = await parse(source);
        if (original.status !== 'complete' || actual.status !== 'complete')
        {
          incomplete = true;
          checks.push({
            rule: 'generated-ownership',
            target,
            path: source.path,
            status: 'incomplete',
            reason:
              'Cannot compare changed generated syntax with the current plan',
          });
        }
        else if (original.fingerprint !== actual.fingerprint)
          add(
            'copied-generated',
            source,
            {name: '<file>', line: 1},
            'Compiler-owned source differs from the generation plan.',
          );
      }
      continue;
    }
    const copy = rawCopies.get(digest(source.content));
    if (copy)
    {
      add(
        'copied-generated',
        source,
        {name: '<file>', line: 1},
        `This file copies compiler-owned ${copy}.`,
      );
      continue;
    }
    const parsed = await parse(source);
    if (parsed.status !== 'complete')
    {
      incomplete = true;
      checks.push({
        rule: 'native-parse',
        target,
        path: source.path,
        status: parsed.status,
        reason: parsed.reason,
      });
      continue;
    }
    for (const reason of parsed.limits ?? [])
    {
      incomplete = true;
      checks.push({
        rule: 'native-construct',
        target,
        path: source.path,
        status: 'unsupported',
        reason,
      });
    }
    for (const imported of parsed.imports ?? [])
    {
      const normalized = imported.replace(/::|\./g, '/').replace(/\/\*$/, '');
      const relative = path.posix
        .normalize(path.posix.join(path.posix.dirname(source.path), imported))
        .replace(/\.[^.]+$/, '');
      const resolved =
        standard.test(imported) ||
        modulePaths.some(
          module =>
            module === relative ||
            module.endsWith('/' + normalized) ||
            module === normalized ||
            module.endsWith('/' + normalized + '/mod') ||
            (target === 'swift' && module.includes('/' + normalized + '/')),
        );
      if (!resolved)
      {
        incomplete = true;
        checks.push({
          rule: 'native-reference',
          target,
          path: source.path,
          status: 'incomplete',
          reason: `Import ${imported} is outside the supplied/generated source inventory; identity resolution is incomplete`,
        });
      }
    }
    const competitors = new Set();
    for (const declaration of parsed.declarations)
    {
      if (boundName(source, declaration, parsed)) continue;
      const clone = baselines.get(declaration.fingerprint);
      const termShape =
        declaration.fields.length > 0 &&
        recordShapes.some(
          fields =>
            JSON.stringify(fields) === JSON.stringify(declaration.fields),
        );
      if (clone || termShape || names.has(declaration.name))
      {
        competitors.add(declaration.name);
        add(
          'native-model',
          source,
          declaration,
          termShape
            ? 'Native dict fields match a generated record schema; review the constructor identity and meaning.'
            : clone
              ? `Declaration matches a supported generated syntax shape in ${clone.path}; review its meaning and ownership.`
              : 'Declaration shares a generated model name; review identity and domain meaning.',
        );
      }
    }
    for (const declaration of parsed.declarations)
    {
      if (
        adapterNames.has(declaration.name) &&
        declaration.identifiers.some(n => competitors.has(n))
      )
        add(
          'adapter-identity',
          source,
          declaration,
          'Adapter refers to a competing local model; check the generated signature and nominal identity.',
        );
      if (
        declaration.identifiers.some(n => names.has(n)) &&
        declaration.identifiers.some(n => competitors.has(n)) &&
        !competitors.has(declaration.name)
      )
        add(
          'manual-conversion',
          source,
          declaration,
          'This function mentions a generated model name and a competing local declaration; review the boundary for migration or supported native bindings.',
        );
    }
  }
  for (const binding of boundTypes)
    if (!observedBindings.has(binding.type))
    {
      incomplete = true;
      checks.push({
        rule: 'native-binding-reference',
        target,
        status: 'incomplete',
        reason: `Bound model ${binding.type} was not resolved to a declaration in the supplied source inventory`,
      });
    }
  check(
    incomplete ? 'incomplete' : 'complete',
    incomplete ? 'Some selected syntax could not be analyzed' : undefined,
  );
  return {findings, checks};
}
export async function collectNativeSources(root)
{
  const sources = [];
  const excluded = new Set([
    'node_modules',
    '.git',
    '.stack-work',
    '.artifacts',
    'vendor',
    'target',
    'build',
    'dist',
    'bin',
    'obj',
    '.venv',
    'venv',
    '__pycache__',
    '.gradle',
    '.lawspec',
  ]);
  async function walk(directory)
  {
    for (const entry of await readdir(directory, {withFileTypes: true}))
    {
      if (entry.isSymbolicLink())
        throw new Error(
          `Native source symlink requires an explicit source selection: ${path.relative(root, path.join(directory, entry.name))}`,
        );
      const file = path.join(directory, entry.name);
      if (entry.isDirectory())
      {
        if (!entry.name.startsWith('.') && !excluded.has(entry.name))
          await walk(file);
      }
      else if (entry.isFile() && extensions[path.extname(file)])
        sources.push({
          path: path.relative(root, file).split(path.sep).join('/'),
          content: await readFile(file, 'utf8'),
        });
    }
  }
  await walk(root);
  return sources;
}
