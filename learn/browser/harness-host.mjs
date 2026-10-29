// Browser host services used by the generated LawSpec JS harness. No Node IO.
// ref:DEC-learn-tests-in-lawspec
/** Supply explicitly bounded in-memory reports and sequential context storage to the unchanged generated harness. ref:DEC-learn-tests-in-lawspec */
export function harnessHostModules()
{
  return {
    'node:fs': `const root='/browser-stats';
const refuse=()=>{const error=new Error('unsupported: native filesystem access is unavailable in browser lessons');error.code='LEARN_UNSUPPORTED_HOST';throw error;};
export function mkdirSync(path){if(path!==root)refuse();}
export function writeFileSync(path,text){if(!path.startsWith(root+'/')||path.includes('/../'))refuse();(globalThis.__harnessReports??=[]).push(JSON.parse(text));}`,
    'node:path': `export const join=(...parts)=>parts.join('/');`,
    'node:async_hooks': `export class AsyncLocalStorage{
 getStore(){return this.value;}
 run(value,callback){
  if(this.active){const error=new Error('unsupported: overlapping asynchronous harness contexts in the sequential browser host');error.code='LEARN_UNSUPPORTED_HOST';throw error;}
  this.active=true;this.value=value;
  const clear=()=>{this.active=false;this.value=undefined;};
  try{const result=callback();if(result&&typeof result.then==='function')return Promise.resolve(result).finally(clear);clear();return result;}catch(error){clear();throw error;}
 }
}`,
  };
}
