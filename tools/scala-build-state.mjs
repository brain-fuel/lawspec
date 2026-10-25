// Generated from templates/tools/scala-build-state.mjs by lawspec-dev generate. Do not edit.
// Preserve a failed Scala compiler invocation before its project is modified.
import {captureScalaBuildFailure} from '../npm/scala-build-state.mjs';
let input='';
for await(const chunk of process.stdin)input+=chunk;
const directory=await captureScalaBuildFailure(JSON.parse(input));
if(directory)console.log(`Scala compiler state: ${directory}`);
