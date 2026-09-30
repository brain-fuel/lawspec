// The part of node:test that generated LawSpec tests use, collecting tests
// for the page's runner.
const registered = (globalThis.__lawspecTests ??= []);
export function test(name, options, fn) {
  registered.push({ name: String(name), fn: typeof options === "function" ? options : fn });
}
export default test;
