// Generated from templates/npm/worker.mjs by lawspec-dev generate. Do not edit.
// The worker half of the Node host (docs/reference/host-effects.md). It runs
// the LawSpec core and blocks in lawspec_host.perform until the main thread
// has performed the effect: the request goes out on a MessagePort, the worker
// waits on a shared flag with Atomics.wait, then takes the reply with
// receiveMessageOnPort (the pattern synckit uses). It contains no LawSpec
// logic. ref:DEC-host-effect-abi
import {readFile} from 'node:fs/promises';
import {
  receiveMessageOnPort,
  workerData,
  parentPort,
} from 'node:worker_threads';
import v8 from 'node:v8';

// Loading node:wasi emits an ExperimentalWarning on every run. The CLI's
// standard error is the command's, as under every other host, so that one
// warning is dropped; every other warning is printed as usual.
const emitWarning = process.emitWarning;
process.emitWarning = (warning, ...rest) =>
{
  const type = typeof rest[0] === 'string' ? rest[0] : rest[0]?.type;
  if (
    type === 'ExperimentalWarning' &&
    /WASI/.test(String(warning?.message ?? warning))
  )
    return;
  emitWarning.call(process, warning, ...rest);
};
const {WASI} = await import('node:wasi');

// node:wasi imports are V8 fast API calls; an allocation inside one can start
// a collection that cannot walk the optimized caller's frame. Ordinary calls
// give the same results. ref:DEC-s1j-shared-failures
v8.setFlagsFromString('--no-turbo-fast-api-calls');

const {corePath, invocation, flag, port} = workerData;
const signal = new Int32Array(flag);
let exports;

function view()
{
  return new Uint8Array(exports.memory.buffer);
}

// A malloc'd buffer: a little-endian u32 length, then the bytes.
function writeBuffer(bytes)
{
  const pointer = exports.lawspec_alloc(bytes.length + 4) >>> 0;
  if (pointer === 0)
  {
    return 0;
  }
  new DataView(exports.memory.buffer).setUint32(pointer, bytes.length, true);
  view().set(bytes, pointer + 4);
  return pointer;
}

function readBuffer(pointer)
{
  const length = new DataView(exports.memory.buffer).getUint32(pointer, true);
  return view().slice(pointer + 4, pointer + 4 + length);
}

function perform(pointer, length)
{
  const request = view().slice(pointer >>> 0, (pointer >>> 0) + length);
  Atomics.store(signal, 0, 0);
  port.postMessage(request, [request.buffer]);
  Atomics.wait(signal, 0, 0);
  const reply = receiveMessageOnPort(port);
  return reply === undefined ? 0 : writeBuffer(reply.message);
}

const module = await WebAssembly.compile(await readFile(corePath));
const wasi = new WASI({version: 'preview1', args: ['lawspec'], env: {}});
const instance = await WebAssembly.instantiate(module, {
  wasi_snapshot_preview1: wasi.wasiImport,
  lawspec_host: {perform},
});
exports = instance.exports;
wasi.initialize(instance);
exports.lawspec_init();
const request = new TextEncoder().encode(JSON.stringify(invocation));
const input = writeBuffer(request);
const output = exports.lawspec_main(input + 4, request.length) >>> 0;
exports.lawspec_free(input);
const outcome = new TextDecoder().decode(readBuffer(output));
exports.lawspec_free(output);
parentPort.postMessage(outcome);
