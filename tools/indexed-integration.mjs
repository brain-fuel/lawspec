// Generate and execute the indexed-family example on every installed native target.
// Correct adapters must pass free, fixed and shared index laws with their
// dependent result contracts; every index-breaking mutant must fail at test time.
import {indexedAdapter, indexedMutants} from './indexed-adapters.mjs';
import {acceptExample} from './example-acceptance.mjs';

await acceptExample({
  name: 'indexed',
  spec: 'indexed_families.lawspec',
  adapterPattern: /(^|\/)(indexed\.(py|mjs|ts|rs)|Indexed\.(java|kt|hs)|indexed\/adapter\.go)$/,
  adapter: indexedAdapter,
  mutants: indexedMutants,
  passed: 'indexed families pass with fixed, shared and free indices',
});
