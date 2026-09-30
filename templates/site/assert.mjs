// The part of node:assert/strict that generated LawSpec tests use.
class AssertionError extends Error {
  constructor(message) {
    super(message);
    this.name = "AssertionError";
  }
}
function ok(value, message) {
  if (!value) throw new AssertionError(message ?? "Expected a truthy value");
}
function equal(actual, expected, message) {
  if (!Object.is(actual, expected)) throw new AssertionError(message ?? `${String(actual)} !== ${String(expected)}`);
}
function fail(message) {
  throw new AssertionError(message ?? "Failed");
}
const assert = Object.assign((value, message) => ok(value, message), { ok, equal, strictEqual: equal, fail, AssertionError });
export { ok, equal, equal as strictEqual, fail, AssertionError };
export default assert;
