// Generate and execute the domain-modeling example on every installed native target.
// Correct adapters must satisfy the wrapper invariants and the workflow's railway
// composition law; every mutant must fail at test time.
import {domainAdapter, domainMutants} from './domain-adapters.mjs';
import {acceptExample} from './example-acceptance.mjs';

await acceptExample({
  name: 'domain',
  spec: 'domain_modeling.lawspec',
  adapterPattern: /(^|\/)(ordering\.(py|mjs|ts|rs)|Ordering\.(java|kt|hs)|ordering\/adapter\.go)$/,
  adapter: domainAdapter,
  mutants: domainMutants,
  passed: 'wrappers and the order workflow pass their laws',
});
