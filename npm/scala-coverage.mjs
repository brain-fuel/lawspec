// Generated from templates/npm/scala-coverage.mjs by lawspec-dev generate. Do not edit.
// lawspec test --coverage on Scala: Scala 3 instruments the code itself
// (-coverage-out, in scoverage's format) and the scoverage reporter, which
// Scala CLI fetches, writes Cobertura, scoverage XML and HTML reports.
import {mkdir, readdir, writeFile} from 'node:fs/promises';
import {spawn} from 'node:child_process';
import path from 'node:path';

export const scoverageReporter = '2.5.2';

// The report script, run by Scala CLI on its own (not as part of the project).
const reportScript = [
  '//> using scala 3.9.0',
  `//> using dep org.scoverage::scalac-scoverage-reporter:${scoverageReporter}`,
  '//> using javaOpt --sun-misc-unsafe-memory-access=allow',
  'import java.io.File',
  'import scoverage.reporter.{CoberturaXmlWriter, IOUtils, ScoverageHtmlWriter, ScoverageXmlWriter}',
  'import scoverage.serialize.Serializer',
  '',
  '@main def report(data: String, sources: String, output: String): Unit = {',
  '  val dataDir = File(data)',
  '  val root = File(sources)',
  '  val coverage = Serializer.deserialize(Serializer.coverageFile(dataDir), root)',
  '  coverage.apply(IOUtils.invoked(IOUtils.findMeasurementFiles(dataDir).toIndexedSeq))',
  '  val out = File(output)',
  '  out.mkdirs()',
  '  CoberturaXmlWriter(Seq(root), out, None).write(coverage)',
  '  ScoverageXmlWriter(Seq(root), out, false, None).write(coverage)',
  '  ScoverageHtmlWriter(Seq(root), out, None).write(coverage)',
  '  println(f"Statement coverage: ${coverage.statementCoveragePercent}%.2f%%")',
  '}',
  '',
].join('\n');

// Where the instrumented runs write their data, under the coverage directory.
export function scalaCoverageData(directory)
{
  return path.join(directory, 'data');
}

// Writes the reports into directory from the runs' data; false when no run
// was measured.
export async function collectScalaCoverage({
  root,
  directory,
  command = 'scala',
  offline = false,
})
{
  const data = scalaCoverageData(directory);
  const files = await readdir(data).catch(() => []);
  if (!files.includes('scoverage.coverage')) return false;
  const script = path.join(directory, 'reporter', 'Report.scala');
  await mkdir(path.dirname(script), {recursive: true});
  await writeFile(script, reportScript);
  const args = [
    'run',
    ...(offline ? ['--offline'] : []),
    script,
    '--',
    data,
    root,
    path.join(directory, 'report'),
  ];
  const status = await new Promise((resolve, reject) =>
  {
    const child = spawn(command, args, {
      cwd: path.dirname(script),
      stdio: ['ignore', 'inherit', 'inherit'],
    });
    child.on('error', reject);
    child.on('close', resolve);
  });
  if (status !== 0)
    throw new Error(
      `the scoverage reporter failed (${command} ${args.join(' ')})`,
    );
  return true;
}
