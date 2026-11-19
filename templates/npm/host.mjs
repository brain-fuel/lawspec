// The main-thread half of the Node host (docs/reference/host-effects.md): it
// starts the core in a worker and performs each effect the core requests.
// It decides nothing about LawSpec: it decodes one request, enforces the
// policy the request carries (the core has already checked it; this is the
// host's independent check), performs that primitive with Node's APIs, and
// encodes the typed result. Errors are results; no exception crosses the
// boundary. ref:DEC-host-effect-abi
import {spawn} from 'node:child_process';
import {randomUUID} from 'node:crypto';
import {
  link,
  lstat,
  mkdir,
  readFile,
  readdir,
  realpath,
  rename,
  rm,
  rmdir,
  stat,
  unlink,
  writeFile,
} from 'node:fs/promises';
import http from 'node:http';
import https from 'node:https';
import os from 'node:os';
import path from 'node:path';
import {isatty} from 'node:tty';
import {MessageChannel, Worker} from 'node:worker_threads';

const ABI = 2;

const kinds = {
  ENOENT: 'not-found',
  EEXIST: 'already-exists',
  EACCES: 'permission-denied',
  EPERM: 'permission-denied',
  ENOTDIR: 'not-a-directory',
  EISDIR: 'is-a-directory',
  ENOTEMPTY: 'directory-not-empty',
  // serve: the port is taken.
  EADDRINUSE: 'already-exists',
};

class HostError extends Error
{
  constructor(kind, message)
  {
    super(message);
    this.kind = kind;
  }
}

const bytes = text => Buffer.from(text, 'base64');
const text = data => Buffer.from(data).toString('base64');

function absolute(file)
{
  if (typeof file !== 'string' || !path.isAbsolute(file))
  {
    throw new HostError('invalid', `path is not absolute: ${file}`);
  }
  return path.normalize(file);
}

// A request's optional permission bits: an integer from 0 to 0o7777, or
// null when absent.
function permissions(request)
{
  const bits = request.permissions ?? null;
  if (bits !== null && (!Number.isInteger(bits) || bits < 0 || bits > 0o7777))
  {
    throw new HostError(
      'invalid',
      'permissions must be an integer from 0 to 0o7777',
    );
  }
  return bits;
}

function entryKind(info)
{
  if (info.isSymbolicLink())
  {
    return 'symlink';
  }
  if (info.isDirectory())
  {
    return 'directory';
  }
  return info.isFile() ? 'file' : 'other';
}

function segments(file)
{
  return file.split('/').filter(part => part !== '');
}

// Whether a normalised absolute path is the root itself or below it.
function within(root, file)
{
  const top = segments(path.normalize(root));
  const parts = segments(path.normalize(file));
  return top.every((part, index) => parts[index] === part);
}

function strings(value, name)
{
  if (!Array.isArray(value) || value.some(item => typeof item !== 'string'))
  {
    throw new HostError(
      'invalid',
      `policy ${name} must be an array of strings`,
    );
  }
  return value;
}

// The policy every request carries: {read, write, programs, network,
// listen}, and the guard's anchors {protected, cwd, projects}, which only
// add refusals and so may be absent.
function policyOf(value)
{
  if (
    value === null ||
    typeof value !== 'object' ||
    typeof value.network !== 'boolean' ||
    typeof value.listen !== 'boolean' ||
    (value.cwd !== undefined &&
      value.cwd !== null &&
      typeof value.cwd !== 'string')
  )
  {
    throw new HostError('invalid', 'the request has no valid policy');
  }
  return {
    read: strings(value.read, 'read'),
    write: strings(value.write, 'write'),
    programs: strings(value.programs, 'programs'),
    network: value.network,
    listen: value.listen,
    protected: strings(value.protected ?? [], 'protected'),
    cwd: value.cwd ?? null,
    projects: strings(value.projects ?? [], 'projects'),
  };
}

// The guard (docs/reference/host-effects.md, Guard): paths no write,
// remove, rename or mkdirs may target, nor an ancestor of them, and that no write
// root may be or contain, whatever the policy grants. The host protects its
// own home and temporary directories besides those the policy names.
const systemProtected = [
  '/',
  '/tmp',
  '/private/tmp',
  '/var/tmp',
  '/private/var/tmp',
  '/var/folders',
  '/private/var/folders',
];

function ownProtected()
{
  return [
    process.env.HOME,
    process.env.TMPDIR,
    os.homedir(),
    os.tmpdir(),
  ].filter(file => typeof file === 'string' && path.isAbsolute(file));
}

// A path under both of its macOS names: /tmp, /var and /etc are links to
// the same names under /private.
function aliases(file)
{
  const parts = segments(path.normalize(file));
  const linked = ['tmp', 'var', 'etc'];
  if (parts[0] === 'private' && linked.includes(parts[1]))
  {
    return [path.normalize(file), '/' + parts.slice(1).join('/')];
  }
  if (linked.includes(parts[0]))
  {
    return [path.normalize(file), '/private/' + parts.join('/')];
  }
  return [path.normalize(file)];
}

// Whether a path is an anchor or an ancestor of one, or macOS's per-user
// temporary directory (/var/folders/xx/yyy/T) or an ancestor of it.
function protects(anchors, file)
{
  if (anchors.flatMap(aliases).some(anchor => within(file, anchor)))
  {
    return true;
  }
  let parts = segments(path.normalize(file));
  if (parts[0] === 'private')
  {
    parts = parts.slice(1);
  }
  if (parts[0] !== 'var' || parts[1] !== 'folders')
  {
    return false;
  }
  const rest = parts.slice(2);
  return rest.length < 3 || (rest.length === 3 && rest[2] === 'T');
}

// The guard's rules over paths in one form (lexical or resolved): anchors
// no write root may be or contain, anchors only a project root may, the
// project roots, the write roots as [shown, compared] and the targets as
// [operation, shown, compared]. A message, or null.
function guarding(hard, soft, projects, roots, targets)
{
  const same = (left, right) => path.normalize(left) === path.normalize(right);
  for (const [shown, root] of roots)
  {
    if (
      protects(hard, root) ||
      (protects(soft, root) && !projects.some(project => same(project, root)))
    )
    {
      return `a write root is a protected path or contains one: ${shown}`;
    }
  }
  for (const [operation, shown, file] of targets)
  {
    if (protects([...hard, ...soft], file))
    {
      return `${operation} of a protected path, or of an ancestor of one, is refused: ${shown}`;
    }
    if (
      ['remove', 'rename'].includes(operation) &&
      (roots.some(([, root]) => same(root, file)) ||
        !roots.some(([, root]) => within(root, file)))
    )
    {
      return `${operation} is allowed only strictly inside a write root, never of one: ${shown}`;
    }
  }
  return null;
}

function anchors(policy)
{
  return {
    hard: [...systemProtected, ...policy.protected, ...ownProtected()],
    soft: [...(policy.cwd === null ? [] : [policy.cwd]), ...policy.projects],
  };
}

// The paths a guarded request targets, as [operation, path, resolution]:
// both of a rename's.
function guardedTargets(request)
{
  switch (request.op)
  {
    case 'write':
    case 'remove':
      return [[request.op, request.path, 'parent']];
    case 'rename':
      return [
        [request.op, request.from, 'parent'],
        [request.op, request.to, 'parent'],
      ];
    case 'mkdirs':
      return [[request.op, request.path, 'whole']];
    default:
      return [];
  }
}

// The paths a request touches: [access, resolution, path]. 'parent' resolves
// only the directory, for operations on a final link itself.
function touched(request)
{
  switch (request.op)
  {
    case 'read':
    case 'list':
    case 'realpath':
      return [['read', 'whole', request.path]];
    case 'stat':
      return [['read', request.follow ? 'whole' : 'parent', request.path]];
    case 'write':
    case 'remove':
      return [['write', 'parent', request.path]];
    case 'rename':
      return [
        ['write', 'parent', request.from],
        ['write', 'parent', request.to],
      ];
    case 'mkdirs':
      return [['write', 'whole', request.path]];
    case 'spawn':
      return [['read', 'whole', request.cwd]];
    default:
      return [];
  }
}

// realpath, keeping missing trailing components.
async function realPath(file)
{
  const missing = [];
  let current = file;
  for (;;)
  {
    try
    {
      return path.join(await realpath(current), ...missing.reverse());
    }
    catch (error)
    {
      const parent = path.dirname(current);
      if (!['ENOENT', 'ENOTDIR'].includes(error.code) || parent === current)
      {
        throw error;
      }
      missing.push(path.basename(current));
      current = parent;
    }
  }
}

async function resolved(resolution, file)
{
  const normal = path.normalize(file);
  if (resolution === 'whole' || normal === '/')
  {
    return realPath(normal);
  }
  return path.join(await realPath(path.dirname(normal)), path.basename(normal));
}

// The host's own check, in the core's order: a malformed request is left
// to the operation, which answers invalid; then the lexical rules, the
// guard first; then the same paths with their symbolic links resolved, and
// the guard over them.
async function enforce(policy, request)
{
  const paths = touched(request);
  const malformed =
    paths.some(
      ([, , file]) => typeof file !== 'string' || !path.isAbsolute(file),
    ) ||
    (request.op === 'spawn' &&
      (!Array.isArray(request.argv) || typeof request.argv[0] !== 'string'));
  if (malformed)
  {
    return;
  }
  const deny = message =>
  {
    throw new HostError('denied', message);
  };
  const {hard, soft} = anchors(policy);
  const targets = guardedTargets(request);
  if (paths.length > 0)
  {
    const problem = guarding(
      hard,
      soft,
      policy.projects,
      policy.write.map(root => [root, path.normalize(root)]),
      targets.map(([operation, file]) => [
        operation,
        file,
        path.normalize(file),
      ]),
    );
    if (problem !== null)
    {
      deny(problem);
    }
  }
  const roots = access =>
    access === 'read' ? [...policy.read, ...policy.write] : policy.write;
  if (request.op === 'spawn' && !policy.programs.includes(request.argv[0]))
  {
    deny(`program not allowed: ${request.argv[0]}`);
  }
  if (request.op === 'fetch')
  {
    if (!policy.network)
    {
      deny('network access is not allowed');
    }
    if (!/^https:\/\//.test(request.url))
    {
      deny(`only https URLs may be fetched: ${request.url}`);
    }
  }
  if (request.op === 'serve' && !policy.listen)
  {
    deny('listening is not allowed');
  }
  for (const [access, , file] of paths)
  {
    if (!roots(access).some(root => within(root, file)))
    {
      deny(`path is outside the sandbox: ${file}`);
    }
  }
  for (const [access, resolution, file] of paths)
  {
    const real = await resolved(resolution, file);
    const allowed = await Promise.all(
      roots(access).map(async root =>
        within(await resolved('whole', root), real),
      ),
    );
    if (!allowed.includes(true))
    {
      deny(`path leaves the sandbox through a symbolic link: ${file}`);
    }
  }
  // The guard again, over the paths resolved through symbolic links; the
  // anchors keep their lexical form as well.
  if (paths.length > 0)
  {
    const whole = file => resolved('whole', file);
    const resolvedHard = await Promise.all(hard.map(whole));
    const resolvedSoft = await Promise.all(soft.map(whole));
    const resolvedProjects = await Promise.all(policy.projects.map(whole));
    const resolvedRoots = await Promise.all(
      policy.write.map(async root => [root, await whole(root)]),
    );
    const resolvedTargets = await Promise.all(
      targets.map(async ([operation, file, resolution]) => [
        operation,
        file,
        await resolved(resolution, file),
      ]),
    );
    const problem = guarding(
      [...hard, ...resolvedHard],
      [...soft, ...resolvedSoft],
      [...policy.projects, ...resolvedProjects],
      resolvedRoots,
      resolvedTargets,
    );
    if (problem !== null)
    {
      deny(problem);
    }
  }
}

// Header lists as [name, value] pairs, names in lower case.
function headerPairs(raw)
{
  const pairs = [];
  for (let index = 0; index + 1 < raw.length; index += 2)
  {
    pairs.push([raw[index].toLowerCase(), raw[index + 1]]);
  }
  return pairs;
}

// One HTTPS request: the core's headers as given (plus Accept-Encoding:
// identity when it sent none), no redirects followed, the body as received.
function fetchOnce(request)
{
  let url;
  try
  {
    url = new URL(request.url);
  }
  catch (error)
  {
    throw new HostError(
      'invalid',
      `invalid URL ${request.url}: ${error.message}`,
    );
  }
  // Raw headers: Node adds no defaults to them, so the framing headers are
  // added here when the core did not send them.
  const headers = request.headers.flat();
  const body = request.body === null ? null : bytes(request.body);
  const sent = name =>
    request.headers.some(([given]) => given.toLowerCase() === name);
  if (!sent('host'))
  {
    headers.push('Host', url.host);
  }
  if (body !== null && !sent('content-length'))
  {
    headers.push('Content-Length', String(body.length));
  }
  if (!sent('accept-encoding'))
  {
    headers.push('Accept-Encoding', 'identity');
  }
  return new Promise((resolve, reject) =>
  {
    const outgoing = https.request(
      url,
      {method: request.method, headers},
      response =>
      {
        const chunks = [];
        response.on('data', chunk => chunks.push(chunk));
        response.on('error', reject);
        response.on('end', () =>
          resolve({
            status: response.statusCode,
            headers: headerPairs(response.rawHeaders),
            body: text(Buffer.concat(chunks)),
          }),
        );
      },
    );
    outgoing.setTimeout(60000, () =>
      outgoing.destroy(
        new HostError('failed', 'no response within 60 seconds'),
      ),
    );
    outgoing.on('error', error =>
      reject(error.kind ? error : new HostError('failed', error.message)),
    );
    outgoing.end(body ?? undefined);
  });
}

// The state of one core run: its processes, listeners and pending requests.
function createEffects()
{
  const processes = new Map();
  const listeners = new Map();
  const requests = new Map();
  const waiters = new Set();
  let next = 1;
  let input = null;

  const wake = () =>
  {
    for (const waiter of waiters)
    {
      waiter();
    }
  };

  // Resolve when ready() holds or the timeout passes.
  function waitFor(ready, timeoutMs)
  {
    if (ready())
    {
      return Promise.resolve();
    }
    return new Promise(resolve =>
    {
      const finish = () =>
      {
        clearTimeout(timer);
        waiters.delete(check);
        resolve();
      };
      const check = () =>
      {
        if (ready())
        {
          finish();
        }
      };
      const timer = setTimeout(finish, Math.max(0, timeoutMs));
      waiters.add(check);
    });
  }

  // The temporary file is created with the permission bits (0666 without),
  // which the umask reduces as open(2) does.
  async function write(file, data, mode, bits)
  {
    await mkdir(path.dirname(file), {recursive: true});
    const temporary = `${file}.lawspec-${randomUUID()}.tmp`;
    try
    {
      await writeFile(temporary, data, {flag: 'wx', mode: bits ?? 0o666});
      if (mode === 'create')
      {
        await link(temporary, file);
      }
      else
      {
        await rename(temporary, file);
      }
    }
    finally
    {
      await unlink(temporary).catch(() =>
      {});
    }
  }

  async function startProcess(request)
  {
    const [program, ...args] = request.argv;
    if (typeof program !== 'string')
    {
      throw new HostError('invalid', 'spawn needs a program');
    }
    const child = spawn(program, args, {
      cwd: absolute(request.cwd),
      env: request.env ?? process.env,
      stdio: ['pipe', 'pipe', 'pipe'],
    });
    await new Promise((resolve, reject) =>
    {
      child.once('spawn', resolve);
      child.once('error', reject);
    });
    const handle = next++;
    const entry = {child, events: [], exited: false};
    processes.set(handle, entry);
    for (const stream of ['stdout', 'stderr'])
    {
      child[stream].on('data', chunk =>
      {
        entry.events.push({handle, stream, data: text(chunk)});
        wake();
      });
    }
    child.on('close', (code, signal) =>
    {
      entry.exited = true;
      entry.events.push(
        signal === null ? {handle, exit: code} : {handle, signal},
      );
      wake();
    });
    child.stdin.on('error', () =>
    {});
    child.stdin.end(request.stdin === null ? undefined : bytes(request.stdin));
    return {handle};
  }

  function known(table, id, name)
  {
    const entry = table.get(id);
    if (entry === undefined)
    {
      throw new HostError('invalid', `unknown ${name} ${id}`);
    }
    return entry;
  }

  async function readInput(max)
  {
    if (input === null)
    {
      input = {chunks: [], ended: false};
      process.stdin.on('data', chunk =>
      {
        input.chunks.push(chunk);
        wake();
      });
      process.stdin.on('end', () =>
      {
        input.ended = true;
        wake();
      });
    }
    await waitFor(() => input.chunks.length > 0 || input.ended, 2 ** 31 - 1);
    const all = Buffer.concat(input.chunks);
    const taken = all.subarray(0, Math.max(1, max));
    input.chunks =
      taken.length < all.length ? [all.subarray(taken.length)] : [];
    return {data: text(taken), eof: taken.length === 0 && input.ended};
  }

  async function serve(port)
  {
    const id = next++;
    const entry = {queue: []};
    const server = http.createServer((request, response) =>
    {
      const body = [];
      request.on('data', chunk => body.push(chunk));
      request.on('end', () =>
      {
        const requestId = next++;
        requests.set(requestId, response);
        entry.queue.push({
          id: requestId,
          method: request.method,
          path: request.url,
          headers: headerPairs(request.rawHeaders),
          body: text(Buffer.concat(body)),
        });
        wake();
      });
    });
    entry.server = server;
    await new Promise((resolve, reject) =>
    {
      server.once('error', reject);
      server.listen(port, '127.0.0.1', resolve);
    });
    listeners.set(id, entry);
    return {listener: id, port: server.address().port};
  }

  const operations = {
    read: async request => ({
      data: text(await readFile(absolute(request.path))),
    }),
    write: async request =>
    {
      await write(
        absolute(request.path),
        bytes(request.data),
        request.mode,
        permissions(request),
      );
      return {};
    },
    list: async request => ({
      entries: (
        await readdir(absolute(request.path), {withFileTypes: true})
      ).map(entry => ({name: entry.name, kind: entryKind(entry)})),
    }),
    stat: async request =>
    {
      const file = absolute(request.path);
      const info = await (request.follow ? stat(file) : lstat(file));
      return {
        kind: entryKind(info),
        size: info.size,
        modifiedMs: Math.floor(info.mtimeMs),
        permissions: info.mode & 0o7777,
      };
    },
    // fs/promises realpath is the C library's realpath(3) (libuv's
    // uv_fs_realpath), which gives the stored case of each name on macOS.
    realpath: async request => ({path: await realpath(absolute(request.path))}),
    remove: async request =>
    {
      const file = absolute(request.path);
      const info = await lstat(file);
      if (info.isDirectory())
      {
        await (request.recursive ? rm(file, {recursive: true}) : rmdir(file));
      }
      else
      {
        await unlink(file);
      }
      return {};
    },
    // rename(2), which fs/promises rename is: it fails across file
    // systems (EXDEV, failed) rather than copying.
    rename: async request =>
    {
      await rename(absolute(request.from), absolute(request.to));
      return {};
    },
    // Each directory a recursive mkdir creates gets the permission bits
    // (0777 without), less the umask; an existing one keeps its own.
    mkdirs: async request =>
    {
      const file = absolute(request.path);
      const bits = permissions(request);
      const info = await stat(file).catch(() => null);
      if (info !== null && !info.isDirectory())
      {
        throw new HostError('already-exists', `not a directory: ${file}`);
      }
      await mkdir(file, {recursive: true, mode: bits ?? 0o777});
      return {};
    },
    spawn: startProcess,
    poll: async request =>
    {
      const entries = request.handles.map(handle =>
        known(processes, handle, 'process handle'),
      );
      await waitFor(
        () => entries.some(entry => entry.events.length > 0),
        request.timeoutMs,
      );
      return {events: entries.flatMap(entry => entry.events.splice(0))};
    },
    kill: async request =>
    {
      const entry = known(processes, request.handle, 'process handle');
      if (!entry.exited)
      {
        entry.child.kill('SIGTERM');
      }
      return {};
    },
    fetch: async request =>
    {
      if (!/^https:\/\//.test(request.url))
      {
        throw new HostError(
          'denied',
          `only https URLs may be fetched: ${request.url}`,
        );
      }
      return fetchOnce(request);
    },
    env: async request => ({value: process.env[request.name] ?? null}),
    clock: async () => ({
      wallMs: Date.now(),
      monotonicUs: Number(process.hrtime.bigint() / 1000n),
    }),
    output: async request =>
    {
      const stream =
        request.stream === 'stderr' ? process.stderr : process.stdout;
      await new Promise(resolve => stream.write(bytes(request.data), resolve));
      return {};
    },
    input: async request => readInput(request.max),
    terminal: async request =>
    {
      const descriptor = ['stdin', 'stdout', 'stderr'].indexOf(request.stream);
      if (descriptor < 0)
      {
        throw new HostError('invalid', `unknown stream ${request.stream}`);
      }
      const terminal = isatty(descriptor);
      // Node knows the width of an output stream that is a terminal.
      const columns =
        terminal && descriptor > 0
          ? (process[request.stream].columns ?? null)
          : null;
      return {terminal, columns: columns > 0 ? columns : null};
    },
    serve: async request => serve(request.port),
    accept: async request =>
    {
      const entry = known(listeners, request.listener, 'listener');
      await waitFor(() => entry.queue.length > 0, request.timeoutMs);
      return {request: entry.queue.shift() ?? null};
    },
    respond: async request =>
    {
      const response = known(requests, request.request, 'request');
      requests.delete(request.request);
      response.writeHead(request.status, request.headers.flat());
      response.end(bytes(request.body));
      return {};
    },
  };

  async function perform(request)
  {
    try
    {
      if (request.abi !== ABI)
      {
        throw new HostError(
          'invalid',
          `unsupported ABI version ${request.abi}`,
        );
      }
      const policy = policyOf(request.policy);
      const operation = operations[request.op];
      if (operation === undefined)
      {
        throw new HostError('unsupported', `unknown operation ${request.op}`);
      }
      await enforce(policy, request);
      return {abi: ABI, ok: await operation(request)};
    }
    catch (error)
    {
      const kind = error.kind ?? kinds[error.code] ?? 'failed';
      return {abi: ABI, error: {kind, message: String(error.message)}};
    }
  }

  function close()
  {
    for (const {child, exited} of processes.values())
    {
      if (!exited)
      {
        child.kill('SIGKILL');
      }
    }
    for (const {server} of listeners.values())
    {
      server.close();
    }
    if (input !== null)
    {
      process.stdin.pause();
    }
  }

  return {perform, close};
}

// Run one invocation of the core: {abi, argv, cwd} or {abi, conformance}.
// Resolves to the core's outcome: {abi, exit}, {abi, notPorted} or {abi, error}.
export async function runCore(corePath, invocation)
{
  const {port1, port2} = new MessageChannel();
  const flag = new SharedArrayBuffer(4);
  const signal = new Int32Array(flag);
  const effects = createEffects();
  const decoder = new TextDecoder();
  const encoder = new TextEncoder();
  port1.on('message', async request =>
  {
    const reply = await effects.perform(JSON.parse(decoder.decode(request)));
    const encoded = encoder.encode(JSON.stringify(reply));
    port1.postMessage(encoded, [encoded.buffer]);
    Atomics.store(signal, 0, 1);
    Atomics.notify(signal, 0);
  });
  const worker = new Worker(new URL('./worker.mjs', import.meta.url), {
    workerData: {corePath: String(corePath), invocation, flag, port: port2},
    transferList: [port2],
  });
  try
  {
    return await new Promise((resolve, reject) =>
    {
      worker.once('message', outcome => resolve(JSON.parse(outcome)));
      worker.once('error', reject);
      worker.once('exit', code =>
        reject(new Error(`the core worker exited with code ${code}`)),
      );
    });
  }
  finally
  {
    effects.close();
    port1.close();
    await worker.terminate();
  }
}
