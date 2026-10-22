// User-owned LawSpec adapter: the approve workflow under the real clock.
import * as ls from '../lawspec_runtime.mjs';
import * as data from '../lawspec_data.mjs';
import * as workflows from '../lawspec_definitions/example/workflows.mjs';
import * as checks from './workflows.mjs';

export async function approvedQuickly(value0) {
  const runtime = new ls.WorkflowRuntime(new ls.RealClock());
  // Approves order value0: whether two of order -1's slow checks that started during this call overlapped in time. Run one after the other they cannot overlap, however loaded the machine is; checks other tests run at the same time never hide this call's own overlap.
  const started = performance.now();
  await workflows.approve(runtime.context(), new data.Order(value0));
  const ran = checks.spans.filter(([start]) => start >= started);
  return value0 !== -1n || ran.some(([a, b], i) => ran.slice(i + 1).some(([c, d]) => a < d && c < b));
}

export async function approvalErrors(value0) {
  checks.finished.length = 0;
  const runtime = new ls.WorkflowRuntime(new ls.RealClock());
  const result = await workflows.approve(runtime.context(), new data.Order(value0));
  if (!(result instanceof data.Left)) return [];
  return result.value.error.map((failure) => failure.error);
}
