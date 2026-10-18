import assert from 'node:assert/strict';
import {readFile,readdir} from 'node:fs/promises';
import {createRequire} from 'node:module';
import vm from 'node:vm';
import {test} from 'node:test';
import {createLawSpecHighlighter,escapeSource} from '../../templates/site/textmate-highlighter.mjs';

const require=createRequire(new URL('../../editors/vscode/package.json',import.meta.url));
const textmate=require('vscode-textmate'),oniguruma=require('vscode-oniguruma');
const shared=await readFile(new URL('../../templates/editors/vscode/syntaxes/lawspec.tmLanguage.json',import.meta.url),'utf8');
const wasm=await readFile(require.resolve('vscode-oniguruma/release/onig.wasm'));
const bytes=wasm.buffer.slice(wasm.byteOffset,wasm.byteOffset+wasm.byteLength);
const browser=vm.createContext({window:{},console,WebAssembly,ArrayBuffer,DataView,Uint8Array,Int8Array,Uint16Array,Int16Array,
  Uint32Array,Int32Array,Float32Array,Float64Array,BigInt64Array,BigUint64Array,TextEncoder,TextDecoder,performance,setTimeout,clearTimeout});
for(const name of ['vscode-textmate','vscode-oniguruma'])
  vm.runInContext(await readFile(require.resolve(name),'utf8'),browser,{filename:name+'.js'});
const highlighter=await createLawSpecHighlighter(browser.vscodetextmate,browser.onig,JSON.parse(shared),bytes);
await oniguruma.loadWASM(bytes);
const registry=new textmate.Registry({onigLib:Promise.resolve({createOnigScanner:p=>new oniguruma.OnigScanner(p),
  createOnigString:s=>new oniguruma.OnigString(s)}),loadGrammar:async name=>name==='source.lawspec'?textmate.parseRawGrammar(shared,'lawspec.tmLanguage.json'):null});
const grammar=await registry.loadGrammar('source.lawspec');
const decode=html=>html.replace(/<[^>]*>/g,'').replace(/&#13;/g,'\r').replace(/&#39;/g,"'").replace(/&quot;/g,'"')
  .replace(/&gt;/g,'>').replace(/&lt;/g,'<').replace(/&amp;/g,'&');

test('site and editor share grammar bytes and locked tokenizer versions',async()=>{
  assert.equal(await readFile(new URL('../../editors/vscode/syntaxes/lawspec.tmLanguage.json',import.meta.url),'utf8'),shared);
  const editor=JSON.parse(await readFile(new URL('../../editors/vscode/package-lock.json',import.meta.url),'utf8'));
  const site=JSON.parse(await readFile(new URL('../../docs/vendor.lock.json',import.meta.url),'utf8'));
  for(const name of ['vscode-textmate','vscode-oniguruma']){
    assert.equal(require(name+'/package.json').version,site[name].version);
    for(const key of ['version','integrity'])assert.equal(site[name][key],editor.packages['node_modules/'+name][key]);
  }
});

test('browser UMD tokenizer scopes match the editor across complete canonical and historical source corpora',async()=>{
  let files=0,lines=0,tokens=0;
  async function* sources(directory){
    for(const entry of (await readdir(directory,{withFileTypes:true})).sort((a,b)=>a.name.localeCompare(b.name))){
      const file=new URL(entry.name+(entry.isDirectory()?'/':''),directory);
      if(entry.isDirectory())yield* sources(file);
      else if(entry.name.endsWith('.lawspec'))yield file;
    }
  }
  for(const folder of ['examples','test/fixtures']){
    const directory=new URL('../../'+folder+'/',import.meta.url);
    for await(const file of sources(directory)){
      const source=await readFile(file,'utf8');
      const web=highlighter.tokenize(source);let state=textmate.INITIAL;
      for(const [index,{line,tokens:actual}]of web.entries()){
        const reference=grammar.tokenizeLine(line,state);state=reference.ruleStack;
        assert.deepEqual(JSON.parse(JSON.stringify(actual)),reference.tokens,file.pathname+':'+(index+1));
        lines++;tokens+=actual.length;
      }
      assert.equal(decode(highlighter.highlight(source)),source,file.pathname);
      files++;
    }
  }
  assert.ok(files>100&&lines>1000&&tokens>5000);
  console.log('TextMate parity:',files,'sources,',lines,'lines,',tokens,'tokens; complete source spelling retained');
});

test('canonical phrase names finish before the body while types and capabilities retain distinct theme scopes',()=>{
  const source='function "|double the value| (value of type Whole) -> Nat is\n  value + value\nend function';
  const highlighted=highlighter.highlight(source);
  assert.equal(decode(highlighted),source);
  assert.match(highlighted,/<span class="hljs-keyword">function<\/span>/);
  assert.match(highlighted,/<span class="hljs-type">Whole<\/span>/);
  assert.match(highlighted,/<span class="hljs-type">Nat<\/span>/);
  assert.doesNotMatch(highlighted,/hljs-string/);
  assert.match(highlighted,/<span class="hljs-keyword">end<\/span>/);
  const capability=highlighter.highlight('requires Eq a\nfunction echo (x :: Integer) -> Integer is x end function');
  assert.match(capability,/<span class="hljs-built_in">Eq<\/span>/);
  assert.match(capability,/<span class="hljs-type">Integer<\/span>/);
  for(const source of ['-- function "|phrase| 😀\nfunction f (x :: Nat) -> Nat is x end function',
    String.raw`function "|read \| metadata| (x :: Text) -> Text is "<script>&\"" end function`,
    '"a multiline\r\ntext <value>"\r\nfunction f (x :: Nat) -> Nat is x end function',
    'authorization `|authorizes| payment\nauthorization `authorizes payment',
    'function Δέντρο (α :: Whole) -> Whole is α end function'])
    assert.equal(decode(highlighter.highlight(source)),source);
  assert.equal(escapeSource('<script>&lt;\r'), '&lt;script&gt;&amp;lt;&#13;');
});
