// Property suites are separate from reusable framework strategy helpers.
export function propertyFiles(files) {
  return files.filter(file => file.placement === 'test' &&
    /(?:LawSpecTest\.(?:java|kt)|Spec\.hs|lawspec_test\.go|_lawspec\.(?:py|rs)|\.lawspec\.test\.(?:mjs|ts))$/.test(file.path));
}
