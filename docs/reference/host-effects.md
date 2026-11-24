---
id: lawspec.reference.host-effects
kind: reference
title: Host effects
---
# Host effects

The LawSpec application runs in Haskell. A host (Node, Go, or the native
executable the JVM packages ship) supplies only primitive effects: it reads
and writes files, runs processes, and talks to the terminal and the network
when the core asks it to. This page specifies that boundary: the module's
exports and import, buffer ownership, the JSON envelope, and every effect.
ref:DEC-host-effect-abi

> **Status.** The ABI, the Haskell interpreters, the Node
> Worker host prototype (`hosts/node/`), the Go host (`hosts/go/`) and the
> conformance suite exist. The ported commands are the usage and option
> checks of every command, `version`, `fmt` (with and without paths),
> `check`, `inspect`, `explain`, `prelude`, `describe`, `generate` (with
> `--check`) for artifact targets and specs-only components, `test`
> (each target's native runner, the result cache and the failure database),
> `prove`, `doctor` and `generate --no-advice` for
> program targets, `fetch`, `update`, `init` and `package`, over local,
> Git and archive packages, the package cache and the
> `.lawspec` cache layout, `project` (with the Canon each host ships; see
> the invocation's `"tools"`), `examples`, `lsp --stdio` and `mcp`. Unknown options and
> missing values are usage errors. Every command runs in the core: since
> 0.36.0 the npm package's `lawspec` is the Node host below, and the legacy
> Node CLI is gone. The ABI
> version is 2; [Changes in ABI 2](#changes-in-abi-2) lists what changed
> from 1, and [Additions to ABI 2](#additions-to-abi-2) the operations
> and fields added since.

## Module

The core is a plain WASI preview1 reactor (`wasm32-wasi`, no JavaScript FFI),
built by `tools/wasm-host-core.sh` into `npm/host-core.wasm`, which the npm
package ships (git ignores it: it is over GitHub's file size limit, and
`npm/build.json` records its digest as `hostCore`).
It imports the WASI preview1 functions the GHC runtime needs and one
LawSpec function. LawSpec's own file, process and network I/O never goes
through WASI, so a host grants no preopens. ref:wasi-preview1

`lawspec-dev integrity` fingerprints the core with the npm package: its
sources (`wasm/host/`, `tools/wasm-host-core.sh` and the compiler's) are
compiler sources in `npm/build.json`, and `tools/wasm.sh` records the
module's SHA-256 as `hostCore` without changing `npm/core.wasm`. The module
is a build output, so integrity checks it whenever it has been built and
says so when it has not.

| Export | Signature | Meaning |
| --- | --- | --- |
| `_initialize` | `() -> ()` | The reactor initializer; call it exactly once, first. ref:ghc-wasm-users-guide |
| `lawspec_init` | `() -> ()` | Start the Haskell runtime (heap bound 3584 MiB, compacting). Call once, after `_initialize`. |
| `lawspec_alloc` | `(len: i32) -> i32` | `malloc`. Returns 0 when memory is exhausted. |
| `lawspec_free` | `(ptr: i32) -> ()` | `free`. |
| `lawspec_main` | `(ptr: i32, len: i32) -> i32` | Run one invocation (below). |
| `lawspec_call` | `(ptr: i32, len: i32) -> i32` | One compiler API request, as in the [compiler API](api.md). |

| Import | Signature |
| --- | --- |
| `lawspec_host.perform` | `(ptr: i32, len: i32) -> i32` |

Pointers are unsigned 32-bit addresses; a host must read them as unsigned
(`>>> 0` in JavaScript).

## Buffers

- A request passed **to** `lawspec_main`, `lawspec_call` or `perform` is
  `len` bytes at `ptr`. The caller owns it; it is valid only during the call.
  A host writes its request into memory from `lawspec_alloc` and frees it
  after the call returns.
- Every returned pointer is a buffer from `lawspec_alloc`: a little-endian
  u32 byte length, then that many bytes. The receiver frees it with
  `lawspec_free`. The core frees `perform` replies; a host frees the replies
  of `lawspec_main` and `lawspec_call`.
- `perform` returning 0 means the host could not reply; the core treats it as
  a `failed` result.
- Calls are serialised. `perform` is synchronous: the core waits in it until
  the reply is written. Allocation is libc, so a host may call
  `lawspec_alloc` inside `perform` without re-entering the Haskell runtime.

## Envelope

Every request and reply is a UTF-8 JSON object with `"abi": 2`. The version
changes only for an incompatible change to the envelope or to an existing
operation; adding an operation does not change it, and a host that predates
an operation answers it `unsupported`. Byte payloads (file
contents, process output, HTTP bodies) are RFC 4648 base64 strings with
padding. Paths are absolute POSIX paths. ref:rfc4648-base64

On Windows a host presents every path to the core as a POSIX path, and
converts every path it receives from the core back before any file system or
process call. The drive is the first segment, with forward slashes:
`C:\Users\me` is `/C:/Users/me`, and a UNC path `\\server\share\dir` is
`//server/share/dir`; a `\\?\` prefix is dropped. The conversion applies to
every path in an invocation (`cwd`, `resources`, the paths of `tools.canon`)
and in every request and response (`read`, `write`, `list`, `stat`,
`realpath`, `remove`, `rename`, `mkdirs`, the `cwd` and program of `spawn`).
On any other platform paths pass unchanged. Every host implements the same
mapping: `hosts/go/internal/effects/winpath.go` and
`templates/npm/core-path.mjs`. The Node host starts a program through
`templates/npm/spawn.mjs`, as LawSpec starts every other tool: on Windows it
resolves PATHEXT and runs `.cmd` and `.bat` files through `cmd.exe`.

An invocation of `lawspec_main`:

```json
{"abi": 2, "argv": ["fmt", "--check", "."], "cwd": "/absolute/working/directory"}
```

A host may add `"build"`, the SHA-256 of the core module it loaded, as a
hexadecimal string; the core names the compiler cache folder below
`.lawspec/cache` by its first 16 digits. Without it the core uses a digest
of its version.

A host may also add `"host": {"kind": "node", "version": "v24.11.0"}`: its
kind (`node`, `go` or `native`) and version. `lawspec test` keys each law's
recorded result by the host that ran the core: its kind, its version and the
core's build, so a result one host recorded is run again, not reused,
under another. The Node and Go hosts send the digest of the core they loaded as
`"build"` with `process.version` and `runtime.Version()`; `lawspec-native`
sends its package version.

A host may also add `"resources"`, the absolute directory of the package
resources it ships: an npm package's directory, whose `learn/`,
`core.wasm`, `core.wasm.gz` and `core_jsffi.js` `lawspec learn` serves
(read-only; the core grants itself read on exactly those). The Node host
sends `LAWSPEC_RESOURCES`, or else its own package; the Go host (`lawspec.WithResources`, which its CLI sets from
`LAWSPEC_RESOURCES`) and `lawspec-native` (from `LAWSPEC_RESOURCES`) ship
no resources of their own and send it only when it is set. Without it,
`lawspec learn` reports its assets missing. A relative or non-string value is `invalid`.

A host may also add `"tools"`, the programs it ships for the core to
run. Its one member so far is `"canon"`, the Canon that `lawspec project`
runs (ref:DEC-native-canon):

```json
{"tools": {"canon": {"command": ["/abs/canon/canon"], "presets": "/abs/canon/presets"}}}
```

`command` is an absolute program and any arguments that come before
Canon's own (`version`, `check`, `decisions`); `presets` is the absolute
directory of Rice's Tax 0.4.3's grammar presets, which `project init` and
`adopt` copy into `.ricestax/` beside a new `canon.yaml`, as ricestax 0.4.3's
`setup.mjs` did. `tools/build-canon.sh` builds the native executable and
gathers the presets into one bundle directory, `<bundle>/canon` and
`<bundle>/presets`. `lawspec-native` and the Go host (`lawspec.WithCanon`,
which its CLI sets from `LAWSPEC_CANON`) send the bundle `LAWSPEC_CANON`
names; without one, the Go host sends the second form instead, naming its
platform and its cache directory:

```json
{"tools": {"canon": {"download": {"platform": "linux-x64", "cache": "/home/u/.cache/lawspec"}}}}
```

`platform` is one of `darwin-arm64`, `darwin-x64`, `linux-arm64` and
`linux-x64`, and `cache` is absolute. The core then downloads this
release's `@goforgedev/canon-<platform>` npm tarball the first time a
project command needs Canon, from `https://registry.npmjs.org` or the
HTTPS registry `LAWSPEC_CANON_REGISTRY` names, refuses it unless its SHA-256 is the one this build records
(`src/LawSpec/App/CanonPackages.hs`, which `lawspec-dev canon-packages
--record` writes at release), and unpacks it into
`<cache>/canon/<version>/<platform>/` with a marker beside it; later runs
reuse an entry whose marker names that digest and whose executable has the
size it was unpacked with, and download a damaged one again. A platform
this build records no digest for downloads nothing, as if no Canon were
shipped, with a message saying so. The host does none of this itself; the JVM launcher sets `LAWSPEC_CANON` to the bundle its platform jar
carries; the Node host sends `LAWSPEC_CANON`, else its optional package
`@goforgedev/canon-<platform>`, else, on a platform with no native Canon
(Windows), its optional ricestax package as
`[node, <ricestax>/bin/ricestax.mjs, "canon"]` with its presets. `CANON`, when set and not empty,
still names the executable that `status` and `validate` run. Without a
Canon, setup fails before writing anything and `status` reports Canon
`incomplete`. Other members of `"tools"` are ignored; a `"canon"` that is not
such an object, or a `"tools"` that is not an object, is `invalid`.

Its outcome is one of:

```json
{"abi": 2, "exit": 0}
{"abi": 2, "notPorted": "command not ported yet: check"}
{"abi": 2, "error": {"kind": "invalid", "message": "cwd must be an absolute path"}}
```

`notPorted` is decided before any effect is performed, so a host may run
another implementation of the command instead. Since 0.36.0 no command
answers it: every command is ported, and the Node host's fallback to the
legacy Node CLI is gone. The outcome stays in ABI 2; a host reports it as
an error. `{"abi": 2, "conformance":
"/empty/scratch/directory"}` runs the host conformance suite instead of a
command.

An effect request names its operation in `op` and carries the policy the
host must enforce ([Sandbox](#sandbox)):

```json
{"abi": 2, "op": "read", "path": "/project/a.lawspec",
 "policy": {"read": [], "write": ["/project"], "programs": [], "network": false, "listen": false,
            "protected": ["/Users/me", "/var/folders/xy/abc/T"], "cwd": "/project", "projects": ["/project"]}}
```

`policy` is required on every request; a host answers a request without a
valid one with `invalid`.

Its reply carries exactly one of `ok` and `error`:

```json
{"abi": 2, "ok": {"data": "dW5pdCBh..."}}
{"abi": 2, "error": {"kind": "not-found", "message": "ENOENT: no such file or directory"}}
```

A failure is always such a result, never an exception crossing the boundary.
`kind` is what the core acts on; `message` is for people.

| Kind | Meaning |
| --- | --- |
| `not-found` | The path, program or handle target does not exist. |
| `already-exists` | An exclusive create met an existing file, or `mkdirs` met a non-directory. |
| `permission-denied` | The operating system refused access. |
| `not-a-directory` | A path component, or a listed path, is not a directory. |
| `is-a-directory` | A file operation met a directory. |
| `directory-not-empty` | A non-recursive remove met a non-empty directory. |
| `denied` | The sandbox policy refused the request. |
| `unsupported` | This host does not provide the effect. |
| `invalid` | A malformed request: a relative path, an unknown handle. |
| `failed` | Any other operating-system or network failure. |

## Effects

| `op` | Request fields | `ok` fields |
| --- | --- | --- |
| `read` | `path` | `data` |
| `write` | `path`, `data`, `mode`: `replace` or `create`, `permissions`: optional | none |
| `list` | `path` | `entries`: `[{name, kind}]`, without `.` and `..`, unordered |
| `stat` | `path`, `follow`: boolean | `kind`, `size`, `modifiedMs`, `permissions`: optional |
| `realpath` | `path` | `path` |
| `remove` | `path`, `recursive`: boolean | none |
| `rename` | `from`, `to` | none |
| `mkdirs` | `path`, `permissions`: optional | none |
| `spawn` | `argv`, `cwd`, `env`: object or null, `stdin`: base64 or null | `handle` |
| `poll` | `handles`, `timeoutMs` | `events`: `[{handle, stream, data}]` or `[{handle, exit}]` or `[{handle, signal}]` |
| `kill` | `handle` | none |
| `fetch` | `url`, `method`, `headers`, `body`: base64 or null | `status`, `headers`, `body` |
| `env` | `name` | `value`: string or null |
| `clock` | none | `wallMs`, `monotonicUs` |
| `output` | `stream`: `stdout` or `stderr`, `data` | none |
| `input` | `max` | `data`, `eof` |
| `terminal` | `stream`: `stdin`, `stdout` or `stderr` | `terminal`: boolean, `columns`: integer or null |
| `serve` | `port` (0 for any) | `listener`, `port` |
| `accept` | `listener`, `timeoutMs` | `request`: `{id, method, path, headers, body}` or null |
| `respond` | `request`, `status`, `headers`, `body` | none |

Entry and stat kinds are `file`, `directory`, `symlink` and `other`.
Headers are arrays of `[name, value]` pairs, so order and repeated names
survive. Header text is Latin-1, and the names a host reports (in `fetch`
responses and `accept` requests) are lower case.

`permissions` is a file's POSIX permission bits as an integer from 0 to
`0o7777` (4095): the owner, group and other bits with set-user-ID,
set-group-ID and sticky, never the file type. It is optional in both
directions. A request without it is the request a host that predates it
decodes, and `stat` leaves it out where the host cannot tell. A value that
is not such an integer is `invalid`.

- **write** is atomic: the host writes a temporary sibling
  (`<path>.lawspec-<unique>.tmp`) exclusively, then renames it over the path
  (`replace`) or hard-links it to the path, failing with `already-exists`
  (`create`), and always removes the temporary file. Missing parent
  directories are created. The temporary file is created with
  `permissions`, or `0o666` without, and the host's file-creation mask
  (umask) removes bits from it as open(2) does. The atomic write then
  renames that file into place, so the path has these bits afterwards even
  when it existed before. A mask leaves the owner's bits alone, so `0o755`
  under the usual mask of `0o022` stays `0o755` and `0o664` becomes `0o644`.
  ref:posix-open
- **stat** with `follow: false` reports a symbolic link itself (lstat).
  `modifiedMs` is whole milliseconds since the Unix epoch. `permissions`
  is `st_mode & 0o7777`.
- **rename** is POSIX rename(2). It moves `from` to `to` atomically,
  replacing an existing file at `to`, or an empty directory there when
  `from` is a directory. It follows neither path's final symbolic link and
  creates no parent. A directory moves with everything in it, and its
  contents keep their names and bits. Error kinds:

  | Case | Kind |
  | --- | --- |
  | `from` is missing, or `to`'s parent is missing | `not-found` |
  | A file over a directory | `is-a-directory` |
  | A directory over a file | `not-a-directory` |
  | A directory over a non-empty directory | `directory-not-empty` (`already-exists` on systems that report `EEXIST`) |
  | `from` and `to` on different file systems | `failed` |

  On different file systems the host never copies. Go's `os.Rename`
  refuses an existing directory as `to`, so the Go host calls
  `syscall.Rename`. ref:posix-rename
- **realpath** is POSIX realpath(3): the path's canonical absolute form,
  with every symbolic link resolved and no `.` or `..`. Every component
  must exist: a missing path or a dangling link is `not-found`, and a
  component that is a file is `not-a-directory`; a loop of links is
  `failed`. The request path is normalised lexically first, as every
  request path is, so `..` is lexical, as in `path.posix`, and the
  sandbox and the operation see the same path. On macOS every name comes
  back in the case stored on disk, as the C library's realpath gives it,
  so `/Users/me/PROJ` on a case-insensitive volume comes back as
  `/Users/me/Proj` when that is the stored name; names on Linux are
  compared exactly. There is no mode that keeps missing trailing
  components: the legacy CLI resolves only paths that exist and treats
  `ENOENT` as an answer. ref:realpath
- **mkdirs** succeeds on an existing directory, which keeps its bits. It
  creates each missing directory, the parents included, with
  `permissions`, or `0o777` without, less the umask, as mkdir(2) does.
  Node's recursive `mkdir` and Go's `os.MkdirAll` behave the same.
- **spawn** starts `argv[0]` (no shell) in `cwd`. A null `env` inherits the
  host's environment; an object replaces it. `stdin` is written and then
  closed; null gives an empty, closed input. A program that cannot be
  started fails at once (`not-found` when it does not exist).
- **poll** waits up to `timeoutMs` until any listed process has events, and
  returns every event available then, possibly none. A process's chunks
  arrive in order and its single `exit` (code) or `signal` (name, such as
  `SIGTERM`) event comes after its last chunk. Order between the two streams
  of one process is not defined.
- **kill** sends SIGTERM to a running process; a finished process is a
  success.
- **fetch** allows only `https:` URLs; anything else is `denied`. The host
  sends the core's method, headers and body, adding only what HTTP/1.1
  framing needs (`Host`, `Content-Length`, `Connection`) and
  `Accept-Encoding: identity` when the core sends no `Accept-Encoding`; it
  adds no `User-Agent`. It follows no redirects (a 3xx is returned as is)
  and decodes no content encoding, so `body` is the bytes received. A URL
  the host's HTTP client cannot parse is `invalid` (the core sends only
  absolute RFC 3986 `https:` URLs, where clients agree); a connection, TLS
  or protocol failure, or no response within 60 seconds, is `failed`. Certificates are checked against
  the host's trust store.
- **clock**: `monotonicUs` is microseconds from a fixed, arbitrary origin and
  never decreases.
- **input** reads at most `max` bytes of standard input, waiting for at
  least one; `eof` is true once the stream is exhausted and `data` is empty.
  A read returns what has arrived, which may be less than `max` and need
  not end at a message boundary. `lawspec lsp --stdio` and `lawspec mcp`
  read their requests this way, one message at a time: the Node host
  buffers `process.stdin` on its main thread while the Worker waits in
  `perform`, the Go host reads it on a goroutine, and `lawspec-native`
  calls `hGetSome`, so each blocks until the client writes and answers
  `eof` once the client closes its end.
- **terminal** says whether the host's own standard stream is a terminal
  (isatty) and, for `stdout` or `stderr` when it is one, its width in
  columns (the `TIOCGWINSZ` ioctl). `columns` is null for a stream that is
  not a terminal, for `stdin`, and when the width is unknown or 0. A stream
  an embedder replaced with something other than an operating-system file
  is not a terminal. The legacy CLI asks this of standard error
  (`process.stderr.isTTY`) to show the running stage on one overwritten
  line, which it cuts to 72 characters without asking the width.
  ref:isatty
- **serve** listens for HTTP on 127.0.0.1 only; a port already in use is
  `already-exists` (`EADDRINUSE`), and another failure to bind is classified
  as any other (`permission-denied` for `EACCES`). **accept** returns the
  next complete request or null after `timeoutMs`; `path` is the request
  target as received (path and query, or an absolute URL), which may be
  any visible ASCII, a malformed percent escape included: the core decides
  what it means. A request whose target has a space, a control character
  or a byte above `0x7E` is answered `400` by the host and never accepted,
  as Node's HTTP parser answers it. **respond** answers it once; an unknown
  or already answered request is `invalid`. The host frames the response
  (`Content-Length` or chunked, `Date`, keep-alive) and sends no body for
  `HEAD`. A listener lives until the invocation ends; `lawspec learn`
  serves until the process is interrupted (`SIGINT`), and every host then
  ends by that signal, as the legacy server did, its listeners closed with
  the process.

## Sandbox

The core checks each request against the command's policy before the host
sees it, and that check is the primary enforcement: readable roots,
writable roots (also readable), the programs that may be spawned (compared
with `argv[0]`), and whether fetching and listening are allowed. Paths are
compared after lexical normalisation, as WASI preopens are.
`lawspec fmt <paths...>` grants the working directory and the named paths.
ref:wasi-capabilities

The core then sends the same policy with the request, and the host enforces
it again on its own, in this order, refusing with `denied`:

1. A malformed request (a touched path that is not absolute, a `spawn`
   without a program) is not refused; the operation answers `invalid`.
2. The [guard](#guard), then the core's rules above, lexically.
3. Each touched path and each root, resolved through symbolic links as
   `realpath` does, keeping missing trailing components, must still nest.
   `read`, `list`, `stat` with `follow`, `realpath`, `mkdirs` and the
   `spawn` `cwd` resolve the whole path; `stat` without `follow`, `remove`,
   both paths of `rename` and `write` resolve only the directory, since
   they act on a final link itself (the atomic write renames over it). A link inside a root that leads outside
   it is therefore refused. The guard is then applied again over the
   resolved paths. ref:realpath

| `policy` field | Meaning |
| --- | --- |
| `read` | Readable roots (directories or single files). |
| `write` | Writable roots; also readable. `rename` needs both of its paths writable. |
| `programs` | Programs `spawn` may start, compared with `argv[0]`. |
| `network` | Whether `fetch` is allowed. |
| `listen` | Whether `serve` is allowed. |
| `protected` | The [guard](#guard)'s protected paths besides its fixed ones: the home and temporary directories the core read from `HOME` and `TMPDIR`. Optional. |
| `cwd` | The invocation's working directory, which the guard protects; a string or `null`. Optional. |
| `projects` | The project roots, which the guard protects but lets be write roots. Optional. |

Requests that touch no path (`poll`, `kill`, `env`, `clock`, `output`,
`input`, `terminal`, `accept`, `respond`) need no grant; `realpath` needs
the path to be readable, as `stat` does. A command's effects run under
its own policy; before a command confines the host, the host enforces the
closed policy, which grants none of the above. The host's check guards
against a defect in the core's check, not against a hostile core, which
could send a wider policy: the trust boundary is the core module the host
loads.

## Guard

A command must never delete or overwrite anything outside its project,
whatever a defect in it grants. (A `doctor` cache probe once treated paths
it could not stat as missing, granted write on `/private` and asked to
remove it recursively.) So every layer, the core first and then each host
on its own, applies a guard before the policy's roots, and refuses with
`denied`, whatever the policy grants:

1. **Protected paths.** No `write`, `remove`, `rename` (either path) or
   `mkdirs` may target a
   protected path or an ancestor of one. Protected are `/`; the system
   temporary roots `/tmp`, `/private/tmp`, `/var/tmp`, `/private/var/tmp`,
   `/var/folders` and `/private/var/folders`, and on macOS each per-user
   temporary directory `/var/folders/xx/yyy/T`, by its shape; the user's
   home and temporary directories; the invocation's working directory; and
   the project roots. Each path is protected under both of its macOS
   names (`/tmp`, `/var` and `/etc` are links into `/private`). A write
   inside the project or below a temporary directory is allowed, since it
   targets neither those paths nor an ancestor.
2. **Write roots.** While a write root is a protected path or contains
   one, every effect that touches a path is refused, the message naming
   the root. A project root may be a write root (`fmt` and `generate`
   write in it) although it contains the working directory, but not one
   that is or contains `/`, a temporary root or the home directory; and a
   project root itself may not be removed or created.
3. **Removal and renaming.** `remove`, recursive or not, is allowed only
   for a path strictly inside a write root, never for a write root itself,
   even one inside another. The same holds for each path of `rename`, so a
   rename can neither move a write root nor replace one.

The core knows the working directory from the invocation, reads `HOME`
and `TMPDIR` with `env` before a command runs, and marks a command's
project roots (the manifest's directory and each target's root, or the
working directory for `fmt <paths...>`) as it grants them; it sends all
of them in the policy's `protected`, `cwd` and `projects`. A host protects
its own home and temporary directories too (Node's `os.homedir()` and
`os.tmpdir()`, Go's `os.UserHomeDir()` and `os.TempDir()`, the native
interpreter's `getHomeDirectory` and `getTemporaryDirectory`, with `HOME`
and `TMPDIR` in each), applies the rules lexically before the roots, and
again after resolving every path through symbolic links as
[Sandbox](#sandbox) step 3 does, the anchors kept in both forms. A link to
the home directory may itself be removed, which touches only the link,
but `mkdirs` through it or a write root that resolves to a protected path
is refused. The rules are the only logic a host holds here; the guard
refuses before any operation touches the disk.

A command that removes what it created removes it under a write grant on
its parent for that removal alone, the path itself no longer a write root, and `doctor` makes its scratch
directories in a `lawspec-scratch` folder of the temporary directory, so
that each one lies strictly inside a write root.
`spawn`'s `cwd` is read access, so the guard does not apply to it; the
processes a command runs are not confined by the policy.

## Haskell interface

Commands are written against `LawSpec.Host.Effect.Host`, a record holding
`perform :: Effect a -> m (Either HostError a)`, where `Effect` is a GADT
indexed by each effect's result type, and `confined :: Policy -> Host m`,
the same host told the policy to enforce again. `LawSpec.Host.Sandbox.sandboxed`
checks a policy and confines the host to it; `enforced` is the host-side
check, which the native and in-memory interpreters share. `LawSpec.Host.Codec` is the envelope.
There are three interpreters:

| Interpreter | Module | Used by |
| --- | --- | --- |
| WebAssembly import | `wasm/host/LawSpec/Host/Wasm.hs` | the core module, in every WebAssembly host |
| Native IO | `LawSpec.Host.Native` | `lawspec-native`, the JVM packages' binary and parity runs |
| In-memory | `LawSpec.Host.Fake` | Hspec |

The native interpreter provides every effect. `rename` is the unix
package's `rename` (rename(2)); `write` passes `permissions` to `openFd`
and `mkdirs` to `createDirectory`, each the mode of open(2) or mkdir(2).
`realpath` calls the C
library's realpath(3); `terminal` uses `hIsTerminalDevice` and the
`TIOCGWINSZ` ioctl, which is variadic, so it is imported with GHC's `capi`
calling convention (a C stub with the header's prototype), never as a plain
`ccall`. ref:ghc-capi `fetch` uses http-client
0.7.19 with http-client-tls 0.3.6.4 (the system trust store); `serve`
binds a network 3.2.9.0 socket on 127.0.0.1 and runs Warp 3.4.9 on it,
each request waiting in its Warp thread until the core responds. The module
and these libraries are built only when not `arch(wasm32)`
(`src-native/`, a `package.yaml` conditional), so the WebAssembly core
never resolves them. ref:http-client ref:http-client-tls ref:warp

`lawspec-native` runs `lawspec_main`'s invocations directly. A `notPorted`
outcome, which no command answers since 0.36.0, would print one line on
standard error, such as `lawspec: 'check' is not available in the native
CLI yet (command not ported yet: check)`, and exit with **69**
(`EX_UNAVAILABLE`), a code LawSpec (0, 1, 2) and Node (1 to 14, 128 plus a
signal) do not use; the Node and Go hosts do the same. ref:sysexits

## Conformance and parity

`LawSpec.Host.Conformance` is one script of effect requests and required
results: files, atomic writes, errors, `rename` (a file over a file, a
directory with its contents, a missing source), `permissions` (`0o700` and
`0o600` through `write` and `stat`, `0o700` through `mkdirs`), `realpath` (a link, a chain of
links, a dangling link, a path through a file, and a name in another case,
which must resolve to the stored name or not be found), `terminal` (standard
input is not a terminal; a stream that is not one has no width),
environment, clocks, processes with
both streams, stdin, environment replacement, working directory and kill,
and the network rules, including loopback round trips in which
`/usr/bin/curl` posts to `serve`, and requests a target with a malformed
percent escape, and the suite accepts each with its target as sent and
responds (a host without curl reports those checks unsupported), and a
second `serve` on a port in use, which must be `already-exists`. It runs under a
conformance policy (the scratch directory writable; `/bin/sh`, curl and a
missing program spawnable; network and listening allowed). Its
confinement checks then send out-of-policy requests to the host confined
to a narrow policy without the core's check, as if the core were wrong,
and require `denied`; its guard checks send the [guard](#guard)'s
refusals the same way (removing a write root itself, `/`, the home
directory, the temporary root or the project root, `mkdirs` at `/`, a
write to an ancestor of the working directory, a rename of a write root
or over one, over the project root or the working directory, of an
ancestor of the working directory or to `/`, and any path effect under
a policy granting write on `/` or the home directory), require sentinel
files to survive them, and still allow a rename and a removal strictly
inside a write root. Each request that names a real protected path is also outside the
narrow policy's roots, so a host without the guard refuses it too and
nothing outside the scratch directory is touched. The other confinement
checks require `denied` for: a read outside the roots, a write to a read-only
root, an ungranted program, a fetch without network, a listener without
permission, a read through a link that leaves its root and a write
through a linked directory, a rename out of or into a read-only root or
through a linked directory, and a `realpath` through a link that leaves its
root; a link's own `stat` stays allowed, and a host not yet confined refuses
files and `realpath` but answers `terminal`.

A host runs the suite through `lawspec_main` with the `conformance`
invocation (`node hosts/node/conformance.mjs <dir>`), and the native
interpreter with `lawspec-native --host-conformance <dir>`. The suite
expects standard input not to be a terminal; `tools/hosts.sh` gives each
host `/dev/null`.
`tools/hosts.sh conformance` runs it over the native interpreter, the Node
host and the Go host; `tools/hosts.sh parity` compares every command's
cases byte for byte (stdout, stderr, exit code and written files) across
`lawspec-native` (the reference), the npm package's CLI (the Node Worker
host), the Go host and the JVM launcher. Until 0.36.0 the reference was the
legacy Node CLI, and every case matched it before it was removed. Its
`--only` and `--jobs` options select cases and bound how many runs go at
once (see docs/how-to/contribute.md).

## Processes in the core

`LawSpec.App.Process` runs toolchains for the commands. A command named
without a slash is looked up on `PATH` as the legacy CLI's `spawn.mjs` does,
and only the program found is granted to `spawn`; a missing one is reported
with the same message and remedy. A process runs until its `exit` event,
polled with at most a second's wait, within the command's wall-clock and
output limits: past either, the core sends `kill` (SIGTERM; the legacy CLI
sent Z3 SIGKILL). Several processes can run at once, their results kept in
the order they started.

`spawn` inherits the host's environment or replaces it, so a process that
needs variables added gets the host's whole environment, read once per
command by running `/usr/bin/env -0` (a read that does not count as a
change), with the additions applied. `argv[0]` stays the toolchain, so the
policy's program check still names it.

`lawspec prove` drives Z3 by its SMT-LIB protocol: the task and
`(check-sat)`, then a follow-up chosen by the first answer line. A process
gets its whole standard input when it starts, so the task runs once ending
in `(exit)`, and a `sat` or `unknown` answer runs it again with the
follow-up (`(get-model)`, `(get-value ...)` or `(get-info
:reason-unknown)`), whose input is exactly the legacy host's; a second run
that answers differently is a failed run. An undecided task therefore takes
up to twice the timeout. The solver's SHA-256 is computed once per command
and again only if its size or modification time changes, where the legacy
host hashed it after every run. The receipt cache's identity names the core
build where the legacy host named its `build.json` and `proof.mjs`, so the
two never reuse each other's receipts.

`lawspec doctor` (and `generate`, which runs it before writing) probes each
program target's toolchain through the same processes, with the legacy
`doctor.mjs` and `beam-doctor.mjs` checks and messages. Probes that must run
inside a toolchain (Python's metadata, Gradle's init script, the BEAM
escript and Mix script, TypeScript's configuration reader, Stack's
read-only hpack hook) are written to a fresh directory under `TMPDIR`,
print facts, and are removed; the decisions are made in the core. Where the
legacy CLI required the Node running it to be 22+ for every target, the
core checks the `node` a JavaScript or TypeScript target's tests run with,
and no Node for other targets, since a host need not be Node.

## Node host

`hosts/node/` runs the core in a worker thread. In `perform` the worker posts
the request to the main thread over a `MessagePort` and blocks in
`Atomics.wait` on a shared flag; the main thread performs the effect with
Node's asynchronous APIs, posts the reply and notifies the flag, and the
worker takes the reply with `receiveMessageOnPort`. This is the mechanism
synckit uses, with the roles reversed. ref:synckit
ref:node-receive-message-on-port

`rename` is `fs/promises` `rename` (`uv_fs_rename`, rename(2));
`permissions` is the `mode` of `writeFile` and of the recursive `mkdir`,
and `stat`'s `mode & 0o7777`.
`realpath` is `fs/promises` `realpath`, which is libuv's `uv_fs_realpath`
over the C library's realpath(3), the same function the native interpreter
calls (`fs.realpathSync` without `.native` is a JavaScript walk that keeps
the case it was given). `terminal` is `tty.isatty` on the descriptor, which
creates no stream, and `columns` of `process.stdout` or `process.stderr`.

## Changes in ABI 2

For a host written against ABI 1:

1. Every request, reply, invocation and outcome carries `"abi": 2`. A host
   refuses a request with another version (`invalid`), and the core
   rejects a reply with another version.
2. Every effect request carries `policy`
   (`{read, write, programs, network, listen}`); a request without a valid
   one is `invalid`. The host enforces it as [Sandbox](#sandbox) orders,
   refusing with `denied`, and starts from the closed policy for any
   request the core sends before a command confines it.
3. `fetch` follows no redirects, sends `Accept-Encoding: identity` when the
   core sends no `Accept-Encoding`, adds no `User-Agent`, decodes no
   content encoding, lower-cases response header names, fails after 60
   seconds without a response and reports a URL it cannot parse as
   `invalid`.
4. `accept` reports request header names in lower case, in the order and
   with the repetitions received.
5. The conformance suite adds the curl round trip and the confinement
   checks; a host passes only if it refuses those requests itself.

## Additions to ABI 2

Adding an operation is compatible ([Envelope](#envelope)), so these keep
`"abi": 2`. A host without one answers it `unsupported`, as for any
operation it does not know, and the core, which has no older host to
support, uses them only where every host it ships with provides them.

1. `realpath` (`path` to `path`), subject to the read policy with the whole
   path resolved, as `stat` with `follow` is.
2. `terminal` (`stream` to `terminal` and `columns`), allowed under every
   policy, as `output` is.
3. The conformance suite adds their checks, including the confinement of
   `realpath`, and runs with standard input that is not a terminal.
4. The policy's optional `protected`, `cwd` and `projects` fields and the
   [guard](#guard), which every host applies; the conformance suite adds
   the guard checks.
5. `rename` (`from` and `to` to nothing). It needs write access to both
   paths, which are resolved as `remove`'s path is, and each path is
   subject to the guard's removal rule.
6. The optional `permissions` of `write` and `mkdirs` requests and of the
   `stat` reply. A host that predates it ignores the field, so its files
   get the default bits, and reports none. The core relies on it only
   where every host it ships with provides it.
7. The conformance suite adds the `rename` checks (a file over a file, a
   directory, a missing source, and the guard and confinement refusals with
   sentinels kept) and the round trip of `permissions` through `write`,
   `mkdirs` and `stat`. A host that reports no bits shows that check as
   unsupported; every POSIX host here passes it.
8. The invocation's optional `"resources"` directory, which a host that
   predates it does not send; `lawspec learn` then reports its assets
   missing.
9. `serve` reports a port in use as `already-exists`, where a host that
   predates this said `failed`, and `accept` passes on any visible-ASCII
   target, a malformed percent escape included, while the host answers
   `400` to a target with any other byte. Node's parser already did both;
   the Go host now reads the request line itself (Go's parser checks the
   target as a URL) and the native host refuses such targets before
   Warp's application sees them. The conformance suite adds both checks.
10. The invocation's optional `"tools"`, with the shipped Canon
    ([Envelope](#envelope)). A host that predates it sends none, and
    `lawspec project` then needs `CANON` for its checks and cannot set
    Canon up.

## Go host

`hosts/go/` is the Go module `goforge.dev/lawspec`: pure Go, no cgo, on
wazero v1.12.0 in compiler mode. ref:wazero-host-modules
[Install the Go host](../how-to/install-go.md) covers installing it.

- **Calls.** wazero calls a host function on the goroutine that called into
  the module, so `perform` needs no second thread: it copies the request out
  of linear memory, performs the effect with Go's standard library, and
  allocates the reply with `lawspec_alloc` from inside the import, which
  wazero allows. Process output, standard input and HTTP requests are
  collected by goroutines into the run's state, and `poll`, `input` and
  `accept` wait on it with their timeouts.
- **Instances.** `lawspec.New` compiles the core once; each invocation runs
  in a fresh, anonymous instance with argv `["lawspec"]`, no environment, no
  preopens, real clocks, `crypto/rand`, and the runtime's own WASI output on
  the process's streams, as in the Node host. A fresh instance costs about
  30 ms, so instances are not reused. The run's processes and listeners are
  stopped when the invocation returns.
- **Memory.** Linear memory is an anonymous mapping reserved at the
  memory's maximum and made accessible as it grows (wazero's
  `experimental.WithMemoryAllocator`, as go-sqlite3 does), so growing it
  never copies and it lives outside Go's heap; wazero's default appends to
  a Go slice and leaves each old copy to the collector. `cmd/lawspec`
  returns the garbage of decoding the core to the system
  (`debug.FreeOSMemory`) before it runs the command.
  ref:wazero-memory-allocator ref:go-sqlite3-alloc
- **Compilation cache.** wazero compiles the 97 MB core on parallel
  goroutines (`experimental.WithCompilationWorkers`; wazero's own default
  is one), and keeps the compiled code, about 330 MB, in `lawspec/wazero`
  under `os.UserCacheDir()`. A cached core compiles nothing.
- **Compilation workers.** `lawspec.WithCompilationWorkers(n)` caps those
  goroutines; `n <= 0`, the default, is `runtime.GOMAXPROCS(0)`, the CPUs
  the process may use, as `nproc` counts them. Go's runtime takes that from
  the `GOMAXPROCS` environment variable when it is set, and otherwise from
  the logical CPUs, the CPU affinity mask and, on Linux, the cgroup CPU
  limit (rounded up, at least 2). The cgroup limit counts since Go 1.25 for
  a main module that declares `go 1.25` or later, as `cmd/lawspec` does
  (`go 1.25.0`, built here with Go 1.26.5); an embedder's program declaring
  an older version gets the CPU count and affinity only
  (`GODEBUG=containermaxprocs=0`). `cmd/lawspec` reads
  `LAWSPEC_COMPILE_WORKERS`, a whole number, for the cap; 0 or less, or
  unset, is the default, and anything else is an error (exit 1).
  ref:go-gomaxprocs
- **The core.** The module does not carry the core: at over 100 MB it is
  past GitHub's file limit, and it is built, not written. Its release and
  SHA-256 are pinned in `hosts/go/internal/core/pin.go`, which
  `lawspec-dev integrity --record` (the last step of `tools/wasm.sh`) writes
  from `package.yaml` and `npm/build.json`'s `hostCore`, and `integrity`
  checks. Without `lawspec.WithCore`, `lawspec.New` uses
  `lawspec/core/<version>/host-core.wasm` under `os.UserCacheDir()` when its
  SHA-256 is the pinned one; otherwise it downloads the npm package
  `@goforgedev/core@<version>` (`tools/package-core.sh` packs it) from
  `https://registry.npmjs.org` or the HTTPS registry
  `LAWSPEC_CORE_REGISTRY` names, reads `package/host-core.wasm` from the
  tarball with the standard library's gzip and tar readers, refuses it
  unless its SHA-256 is the pinned one, and keeps it there with a temporary
  file and a rename. This happens before the core runs, so it is the one
  step the host takes on its own; the core still downloads Canon itself.
  ref:DEC-go-core-download
- **Commands.** `cmd/lawspec` sends `os.Args[1:]` and the physical working
  directory (`getcwd`, as Node and the native CLI report it) to
  `lawspec_main` and exits with the command's code. A `notPorted` outcome
  (none occurs since 0.36.0) prints the core's message and exits with 69
  (`EX_UNAVAILABLE`). `go run ./internal/cmd/conformance <dir>` runs the
  conformance suite. `LAWSPEC_HOST_CORE` names another core for either,
  which is not checked against the pin (a core built from source;
  `tools/hosts.sh` and `tools/host-parity.mjs` pass `npm/host-core.wasm`).
- **Sandbox.** Each request's policy is enforced as [Sandbox](#sandbox)
  orders, with `filepath.EvalSymlinks` as the resolver: it resolves links
  as `realpath` does, and the missing trailing components are kept by
  resolving the longest existing prefix. It keeps the case it is given,
  which is safe because the touched path and the roots are resolved the
  same way and compared exactly.
- **rename and permissions.** `rename` is `syscall.Rename` (rename(2)),
  since `os.Rename` refuses an existing directory as the new name.
  `permissions` becomes the `fs.FileMode` of `os.OpenFile` and
  `os.MkdirAll`, the set-user-ID, set-group-ID and sticky bits as
  `fs.ModeSetuid`, `fs.ModeSetgid` and `fs.ModeSticky`, and `stat` maps the
  mode back.
- **realpath.** `filepath.EvalSymlinks` resolves the links (`lstat` and
  `readlink`, as the C library does), and on macOS each name of the result
  then takes its stored case from `getattrlist(2)` (`ATTR_CMN_NAME`,
  without following links), which, like realpath(3), needs only search
  permission on the parents; opening the file for `F_GETPATH` would need
  read permission. A mount point keeps the name in the path, since
  `getattrlist` names a volume's root by the volume. `x/sys/unix` has no
  `getattrlist` wrapper, so it is called through `unix.Syscall6`; there is
  no cgo. On Linux `EvalSymlinks`' result is realpath(3)'s.
  ref:macos-getattrlist
- **terminal.** A stream with a descriptor (`Fd()`) is a terminal when
  `TIOCGETA` (BSDs and macOS) or `TCGETS` (Linux) reads its attributes, as
  isatty does, and its width is `TIOCGWINSZ`'s, through `x/sys/unix`.
- **HTTP.** Go's `net/http` server and client keep headers in a map, which
  loses the order and repetition the ABI reports, so both directions frame
  HTTP/1.1 on Go's own parser instead: the host peeks the raw header block
  on the buffered connection (`bufio.Reader.Peek`) to list its fields as
  received. `fetch` then has `http.ReadResponse` consume the same bytes
  and read the body (Content-Length, chunked or close-delimited). `serve`
  takes the request target from the request line as received (visible
  ASCII, otherwise `400`), has `http.ReadRequest` parse a copy of the
  block with the target replaced by `/` (it would reject a target that is
  not a valid URL, such as one with a malformed percent escape, which
  Node's parser passes on), then consumes the block and reads the body as
  the parsed headers frame it (Content-Length, or chunked with
  `httputil.NewChunkedReader` and the trailer fields after it). `serve`
  keeps connections alive, answers
  `Expect: 100-continue`, and writes the core's response headers in its
  order, adding only `Date`, `Content-Length` and `Connection: close`
  where needed. `fetch` dials TLS itself (`crypto/tls`, the system trust
  store, HTTP/1.1 by ALPN, no proxy, as Node's `https.request`), writes the
  core's headers in order and as spelled, uses one connection per
  request (`Connection: close` unless the core sends `Connection`), and
  times out after 60 seconds without progress, as Node's socket timeout
  does. ref:go-http-read-request
- **Differences from Node.** Results, error kinds and header lists are the
  same. Node's `https.request` frames a body-less `POST` as chunked;
  the Go host sends such a request without a body. The unit tests in
  `internal/effects` cover an HTTPS `fetch` (headers in received order, a
  redirect returned as is, no content decoding, no `User-Agent`), keep-alive
  `serve`, `accept` and `respond`, and the confinement rules.
- **Measured** (2026-11-13, Apple M5 Max, 18 cores, shared at a load average
  of 5 to 8, hosts run one at a time, so read ratios). Starting the core and
  refusing an invocation takes 1.5 s with an empty cache (9.6 s before
  compilation was parallel) and 0.75 s cached, against about 0.3 s for the
  Node host. `fmt --check` over `examples/specs` takes 14.5–15.6 s against
  10.1–11.6 s for the Node host and 2.6 s for `lawspec-native`, at a peak
  RSS of 0.75 GB (1.0–1.12 GB with wazero's default memory; Node host 0.45
  GB, native 0.22 GB). A CPU profile of that run puts 93% of samples in the
  core's compiled code and under 1% in `perform`, JSON, base64 and system
  calls, so the remaining time is wazero's code against V8's. Of the memory,
  about 330 MB is wazero's compiled code (wazero compiles every function
  ahead of time; V8 compiles lazily), about 165 MB is wazero's decoded
  module, which it keeps in Go's heap for the compiled module's life (103 MB
  of it function bodies, which compiled or cached code no longer needs),
  with the collector's headroom over it, 97 MB the embedded module and 71 MB
  the core's linear memory. wazero's interpreter did not finish the run
  within 300 s, at 3.7 GB.
