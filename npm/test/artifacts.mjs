// Generated from templates/npm/test/artifacts.mjs by lawspec-dev generate. Do not edit.
// Property suites are separate from reusable framework strategy helpers.
export function propertyFiles(files) {
  return files.filter(file => file.placement === 'test' &&
    (/(?:LawSpecTest\.(?:java|kt|scala)|Spec\.hs|lawspec_test\.go|_lawspec\.(?:py|rs)|\.lawspec\.test\.(?:mjs|ts)|_lawspec_tests\.erl|_lawspec_test\.(?:exs|gleam))$/.test(file.path) ||
      // .NET: one file of laws per unit; models, crypto vectors and native generators apart.
      /^tests\/LawSpec\/(?!CryptoVectors\.|NativeGenerators\.)[A-Za-z0-9]+(?<!Models)\.(?:fs|cs)$/.test(file.path)));
}

// Elixir and Gleam suites delegate their assertions and example metadata to
// generated Erlang case modules. Reusable runtime helpers are not properties.
export function propertyContent(files) {
  const cases = files.filter(file => file.placement === 'test' && /_lawspec_cases\.erl$/.test(file.path));
  return [...propertyFiles(files), ...cases].map(file => file.content).join('\n');
}
