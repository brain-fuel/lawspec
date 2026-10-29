/** Compare an actual run with a scene's checked teaching observations without changing the execution verdict. ref:DEC-learn-executable-story */
export function expectationProblems(result, expected)
{
  const problems = [];
  if (result.mode !== expected.mode)
  {
    problems.push('A different set of checks ran.');
  }
  if (result.ok !== (expected.expect === 'passed'))
  {
    problems.push('The overall execution outcome differs.');
  }
  for (const name of expected.failedTests ?? [])
  {
    if (
      !result.tests.some(row => row.name === name && row.status === 'failed')
    )
    {
      problems.push('Missing failing check: ' + name);
    }
  }
  if (expected.sampled && result.sampled?.status !== expected.sampled)
  {
    problems.push('The sampled property outcome differs.');
  }
  if (
    expected.counterexample &&
    JSON.stringify(result.sampled?.counterexample) !==
      JSON.stringify(expected.counterexample)
  )
  {
    problems.push('The final counterexample differs.');
  }
  if (
    expected.minShrinks &&
    !(result.sampled?.numShrinks >= expected.minShrinks)
  )
  {
    problems.push('The required shrinking was not observed.');
  }
  return problems;
}
