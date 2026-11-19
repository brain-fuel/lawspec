#!/usr/bin/env node
// Generated from templates/hosts/node/conformance.mjs by lawspec-dev generate. Do not edit.
// Run the core's host conformance suite (LawSpec.Host.Conformance) over this
// host (npm/host.mjs): node hosts/node/conformance.mjs <empty scratch directory>. The suite
// and its expectations live in the core, so every host runs the same one.
// ref:DEC-host-effect-abi
import path from 'node:path';
import {fileURLToPath} from 'node:url';
import {runCore} from '../../npm/host.mjs';

const scratch = process.argv[2];
if (!scratch)
{
  process.stderr.write('usage: conformance.mjs <empty scratch directory>\n');
  process.exit(2);
}
const corePath =
  process.env.LAWSPEC_HOST_CORE ??
  fileURLToPath(new URL('../../npm/host-core.wasm', import.meta.url));
const outcome = await runCore(corePath, {
  abi: 2,
  conformance: path.resolve(scratch),
});
process.exitCode = typeof outcome.exit === 'number' ? outcome.exit : 1;
