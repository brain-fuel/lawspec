// Native JetCheck factory composition, shrink replay, and failure semantics.
import assert from 'node:assert/strict';
import {execFileSync} from 'node:child_process';
import {mkdir, readFile, writeFile} from 'node:fs/promises';
import path from 'node:path';
import os from 'node:os';
const root=path.resolve(import.meta.dirname,'..');
const jar=process.env.LAWSPEC_JETCHECK_JAR ?? path.join(os.homedir(),
  '.m2/repository/org/jetbrains/jetCheck/0.3.0/jetCheck-0.3.0.jar');
const formatter=process.env.LAWSPEC_GOOGLE_JAVA_FORMAT ?? path.join(os.homedir(),
  '.m2/repository/com/google/googlejavaformat/google-java-format/1.36.0/google-java-format-1.36.0-all-deps.jar');
const directory=path.join(root,'.artifacts/java-native-generators');
const classes=path.join(directory,'classes');
await mkdir(classes,{recursive:true});
for (const name of ['runtime/LawSpecDataStrategies.java','test/runtime/JavaNativeGeneratorsCheck.java']) {
  const file=path.join(root,name);
  assert.equal(await readFile(file,'utf8'),
    execFileSync('java',['-jar',formatter,file],{encoding:'utf8'}),`Google Java Format: ${name}`);
}
execFileSync('javac',['--release','25','-cp',jar,'-d',classes,
  ...['runtime/LawSpecRuntime.java','runtime/LawSpecSchema.java','runtime/LawSpecDataStrategies.java',
    'test/runtime/JavaNativeGeneratorsCheck.java','test/runtime/JavaCheckedStrategiesCheck.java']
    .map(name=>path.join(root,name))],{stdio:'inherit'});
for (const bits of [32,64]) for (const check of ['JavaNativeGeneratorsCheck','JavaCheckedStrategiesCheck']) {
  const log=execFileSync('java',['-cp',[classes,jar].join(path.delimiter),check,String(bits)],{encoding:'utf8'});
  await writeFile(path.join(directory,`${check}-${bits}.log`),log);
  console.log(log.trim());
}
