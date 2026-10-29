// Generated from templates/npm/test/artifacts.mjs by lawspec-dev generate. Do not edit.
// Property suites are separate from reusable framework strategy helpers.
export function propertyFiles(files)
{
  // A Groovy project's Spock specifications run the laws through the Java
  // cases beside them (AlgebraLawSpecTest.java for AlgebraLawSpec.groovy),
  // which are support, not suites of their own.
  const clojure = files.some(file => file.path.endsWith('_lawspec_test.clj'));
  const spock = new Set(
    files
      .filter(file => file.path.endsWith('LawSpec.groovy'))
      .map(file =>
        file.path
          .split('/')
          .at(-1)
          .replace(/\.groovy$/, 'Test.java'),
      ),
  );
  return files.filter(
    file =>
      file.placement === 'test' &&
      !spock.has(file.path.split('/').at(-1)) &&
      !(
        clojure &&
        file.path.startsWith('java/test/') &&
        file.path.endsWith('LawSpecTest.java')
      ) &&
      (/(?:LawSpecTest\.(?:java|kt|scala)|LawSpec\.groovy|_lawspec_test\.clj|Spec\.hs|lawspec_test\.go|_lawspec\.(?:py|rs)|\.lawspec\.test\.(?:mjs|ts)|_lawspec_tests\.erl|_lawspec_test\.(?:exs|gleam))$/.test(
        file.path,
      ) ||
        // .NET and Swift: one file of laws per unit; models, crypto vectors,
        // native generators and Swift's root suites apart.
        /^tests\/LawSpec\/(?!CryptoVectors\.|NativeGenerators\.|LawSpecTests\.)[A-Za-z0-9]+(?<!Models)\.(?:fs|cs|swift)$/.test(
          file.path,
        )),
  );
}

// Elixir and Gleam suites delegate their assertions and example metadata to
// generated Erlang case modules, Clojure's to Java law cases and Groovy's
// Spock specifications to the Java cases beside them. Reusable
// runtime helpers are not properties.
export function propertyContent(files)
{
  const spock = files.some(file => file.path.endsWith('LawSpec.groovy'));
  const clojure = files.some(file => file.path.endsWith('_lawspec_test.clj'));
  const cases = files.filter(
    file =>
      file.placement === 'test' &&
      (/(?:_lawspec_cases\.erl|LawCases\.java)$/.test(file.path) ||
        ((spock || (clojure && file.path.startsWith('java/test/'))) &&
          file.path.endsWith('LawSpecTest.java'))),
  );
  return [...propertyFiles(files), ...cases]
    .map(file => file.content)
    .join('\n');
}
