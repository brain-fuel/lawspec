/** Render a compiler-provided law label without its phrase delimiters. ref:DEC-learn-english-names */
export function lawLabel(name)
{
  return name.startsWith('|') && name.endsWith('|')
    ? name.slice(1, -1).replace(/\\([|\\])/g, '$1')
    : name;
}
/** Match executed checks to authoritative compiler metadata; retain raw identities separately. ref:DEC-learn-novice-results */
export function describeCheck(name, checks = [])
{
  const check = checks
    .filter(row => name === row.name || name.startsWith(row.name + ' '))
    .sort((a, b) => b.name.length - a.name.length)[0];
  if (!check)
  {
    return {label: name, kind: 'Check'};
  }
  return {
    label: check.label,
    kind: name.endsWith(' property')
      ? 'Generated trials'
      : check.quantified
        ? 'Boundary inputs'
        : 'Specific inputs',
  };
}
/** Count actual fast-check trials separately from named properties and accepted shrinking steps. ref:DEC-learn-novice-results */
export function runSummary(result, elapsed)
{
  const parts = [
    `${result.tests.length} ${result.tests.length === 1 ? 'check' : 'checks'}`,
  ];
  if (result.properties.length)
  {
    const trials = result.properties.reduce(
      (count, row) => count + row.numRuns,
      0,
    );
    const shrinks = result.properties.reduce(
      (count, row) => count + row.numShrinks,
      0,
    );
    parts.push(
      `${result.properties.length} sampled ${result.properties.length === 1 ? 'property' : 'properties'}`,
      `${trials} generated trials`,
    );
    if (shrinks)
    {
      parts.push(`${shrinks} smaller failing cases kept`);
    }
  }
  parts.push(`${Math.round(elapsed)} ms`);
  return parts.join(' · ');
}
/** Show observed calls in the selected implementation language, respecting tuple versus list inputs. ref:DEC-learn-novice-results */
export function observedCall(binding, call, language)
{
  const values = binding.inputs.length > 1 ? call.input : [call.input];
  const literal = value =>
    Array.isArray(value)
      ? '[' + value.map(literal).join(language === 'fsharp' ? '; ' : ', ') + ']'
      : String(value);
  const args = values.map(value =>
    language === 'fsharp' && typeof value === 'number' && value < 0
      ? '(' + value + ')'
      : literal(value),
  );
  const invocation =
    language === 'fsharp'
      ? binding.name + ' ' + args.join(' ')
      : binding.name + '(' + args.join(', ') + ')';
  return invocation + ' → ' + literal(call.output);
}
