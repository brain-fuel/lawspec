// Generated from templates/npm/node-events-reporter.mjs by lawspec-dev generate. Do not edit.
// Node's structured reporter stream preserves names without XML encoding.
// A nonce and final seal tie execution evidence to this invocation only.
export default async function* report(source)
{
  const run = process.env.LAWSPEC_NODE_RUN;
  if (!run)
    throw new Error('LawSpec Node reporting requires an invocation identity');
  const row = value => JSON.stringify({version: 1, run, ...value}) + '\n';
  let count = 0;
  yield row({event: 'start'});
  for await (const event of source)
  {
    if (
      !['test:pass', 'test:fail'].includes(event.type) ||
      event.data?.details?.type === 'suite'
    )
      continue;
    const data = event.data;
    const skipped = [data.skip, data.todo].some(
      value => value !== undefined && value !== false,
    );
    const duration = data.details?.duration_ms;
    const failure = data.details?.error?.message;
    yield row({
      event: 'test',
      name: data.name,
      classname: data.file ?? '',
      status: skipped
        ? 'skipped'
        : event.type === 'test:pass'
          ? 'passed'
          : 'failed',
      ...(Number.isFinite(duration) && duration >= 0
        ? {time: duration / 1000}
        : {}),
      ...(event.type === 'test:fail'
        ? {
            failure:
              typeof failure === 'string' ? failure : 'native test failed',
          }
        : {}),
    });
    count++;
  }
  yield row({event: 'end', count});
}
