// User-owned LawSpec adapter: the approve workflow under the real clock.
import * as ls from '../lawspec_runtime.mjs';
import * as data from '../lawspec_data.mjs';
import * as workflows from '../lawspec_definitions/example/workflows.mjs';
import * as checks from './workflows.mjs';

export async function approvedQuickly(value0) {
  const runtime = new ls.WorkflowRuntime(new ls.RealClock());
  const started = performance.now();
  await workflows.approve(runtime.context(), new data.Order(value0));
  return performance.now() - started < 550;
}

export async function approvalErrors(value0) {
  checks.finished.length = 0;
  const runtime = new ls.WorkflowRuntime(new ls.RealClock());
  const result = await workflows.approve(runtime.context(), new data.Order(value0));
  if (!(result instanceof data.Left)) return [];
  return result.value.error.map((failure) => failure.error);
}
