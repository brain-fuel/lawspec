import {test} from 'node:test';
import {foldingChecks} from './case-fold-checks.mjs';

test('pinned full Unicode folding preserves author names, scope and mandatory checks through the WASM API at 32 bits',()=>foldingChecks(32));
