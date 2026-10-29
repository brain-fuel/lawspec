// Use pinned Eclipse JDT with Google's archived profile and owner overrides.
// ref:DEC-google-style-allman
import {execFileSync} from 'node:child_process';
import {fileURLToPath} from 'node:url';
const root = fileURLToPath(
  new URL(
    import.meta.url.includes('/templates/') ? '../../' : '../',
    import.meta.url,
  ),
);
if (!process.argv[2])
{
  throw new Error('Usage: node tools/java-style.mjs <complete Java files...>');
}
const classpath = execFileSync(
  'coursier',
  [
    'fetch',
    '--classpath',
    'org.eclipse.jdt:org.eclipse.jdt.core:3.47.0',
    'org.eclipse.platform:org.eclipse.jface.text:3.31.100',
  ],
  {encoding: 'utf8'},
).trim();
execFileSync(
  'java',
  [
    '-cp',
    classpath,
    root + 'tools/JavaCodeStyle.java',
    root + 'test/locks/java-eclipse.xml',
    ...process.argv.slice(2),
  ],
  {stdio: 'inherit'},
);
