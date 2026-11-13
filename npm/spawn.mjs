// Generated from templates/npm/spawn.mjs by lawspec-dev generate. Do not edit.
// Starts the native tools LawSpec drives: build tools, test runners, solvers.
//
// POSIX starts the command as given. Windows needs two things Node leaves to
// its callers. CreateProcess does not apply PATHEXT, so `mvn` never finds
// `mvn.cmd`; and Node refuses to start a batch file without a shell
// (CVE-2024-27980, EINVAL since Node 18.20.2, 20.12.2 and 21.7.3). A batch
// file therefore runs through `cmd.exe /d /s /c "<command line>"` with the
// command line written here and passed verbatim.
//
// The quoting follows the Rust standard library's fix for the same defect
// (CVE-2024-24576, library/std/src/sys/args/windows.rs, make_bat_command_line
// and append_bat_arg) rather than cross-spawn's caret escaping. Carets are
// consumed once per parse, and a batch file that forwards %* is parsed again
// by cmd an unknown number of times; a quoted argument whose own quotes are
// doubled keeps cmd inside the quotes on every parse. The resolution order
// follows libuv and node-which: the working directory, then PATH, each with
// the PATHEXT extensions.
//
// resolveCommand, quoteBatchArgument, batchCommandLine, invocation,
// notFoundMessage and shellHint are pure: they read only their arguments.
import {execFile, spawn, spawnSync} from 'node:child_process';
import {statSync} from 'node:fs';
import path from 'node:path';

const defaultPathExt = '.COM;.EXE;.BAT;.CMD';
// cmd.exe rejects a longer command line.
const cmdLineLimit = 8191;

export class ToolNotFoundError extends Error
{
  constructor(command, resolution)
  {
    super(notFoundMessage(command, resolution));
    this.name = 'ToolNotFoundError';
    // Callers that already treat a missing executable as unavailable keep
    // doing so.
    this.code = 'ENOENT';
    this.command = command;
    this.searched = resolution.searched;
  }
}

export class UnsafeArgumentError extends Error
{
  constructor(message)
  {
    super(message);
    this.name = 'UnsafeArgumentError';
    this.code = 'LAWSPEC_UNSAFE_ARGUMENT';
  }
}

function isFile(file)
{
  try
  {
    return statSync(file).isFile();
  }
  catch
  {
    return false;
  }
}

// Windows environment names are case-insensitive: PATH is usually `Path`.
export function environmentValue(env, name, platform = process.platform)
{
  if (platform !== 'win32') return env[name];
  if (env[name] !== undefined) return env[name];
  const wanted = name.toLowerCase();
  for (const [key, value] of Object.entries(env))
    if (key.toLowerCase() === wanted) return value;
  return undefined;
}

// Where a command would be found. Returns {found: true, file, batch} or
// {found: false, explicit, directories, extensions, searched}; `searched`
// lists every file looked for, in order.
export function resolveCommand(
  command,
  {
    platform = process.platform,
    env = process.env,
    cwd = process.cwd(),
    exists = isFile,
  } = {},
)
{
  const windows = platform === 'win32';
  const paths = windows ? path.win32 : path.posix;
  const explicit = windows
    ? /[\\/]/.test(command) || /^[A-Za-z]:/.test(command)
    : command.includes('/');
  const entries = String(environmentValue(env, 'PATH', platform) ?? '')
    .split(paths.delimiter)
    .map(entry => (windows ? entry.replaceAll('"', '') : entry));
  let directories;
  if (explicit) directories = [];
  else if (windows)
  {
    // cmd.exe and libuv look in the working directory first, unless the
    // user has turned that off.
    const skipCurrent =
      environmentValue(env, 'NoDefaultCurrentDirectoryInExePath', platform) !==
      undefined;
    directories = [
      ...(skipCurrent ? [] : [cwd]),
      ...entries.filter(Boolean).map(entry => paths.resolve(cwd, entry)),
    ];
  }
  // An empty POSIX PATH entry names the working directory.
  else directories = entries.map(entry => paths.resolve(cwd, entry));
  directories = [...new Set(directories)];
  let extensions = [''];
  if (windows)
  {
    const listed = String(
      environmentValue(env, 'PATHEXT', platform) || defaultPathExt,
    )
      .split(';')
      .map(extension => extension.trim())
      .filter(extension => extension.startsWith('.') && extension.length > 1);
    // A name with an extension is tried as written first. A name without one
    // is never tried bare: `gradlew` beside `gradlew.bat` is a shell script
    // Windows cannot start.
    extensions = paths.extname(command) ? ['', ...listed] : listed;
  }
  const bases = explicit
    ? [paths.resolve(cwd, command)]
    : directories.map(directory => paths.join(directory, command));
  const searched = [];
  for (const base of bases)
    for (const extension of extensions)
    {
      const file = base + extension;
      searched.push(file);
      if (exists(file))
        return {
          found: true,
          file,
          batch: windows && /\.(?:cmd|bat)$/i.test(file),
        };
    }
  return {found: false, explicit, directories, extensions, searched};
}

// The manifest field that names a tool, and what to install otherwise.
const advice = {
  mvn: [':maven', 'Maven'],
  mvnw: [':maven', 'Maven'],
  gradle: [':gradle', 'Gradle'],
  gradlew: [':gradle', 'Gradle'],
  python: [':python', 'Python'],
  python3: [':python', 'Python'],
  cargo: [':cargo', 'Rust'],
  rustc: [':rustc', 'Rust'],
  scala: [':scala', 'Scala CLI'],
  clojure: [':clojure', 'the Clojure CLI'],
  swift: [':swift', 'Swift'],
  dotnet: [':dotnet', 'the .NET SDK'],
  node: [null, 'Node.js'],
  npm: [null, 'Node.js'],
  npx: [null, 'Node.js'],
  go: [null, 'Go'],
  stack: [null, 'Stack'],
  ghc: [null, 'GHC'],
  mix: [null, 'Elixir'],
  rebar3: [null, 'Rebar3'],
  erl: [null, 'Erlang/OTP'],
  erlc: [null, 'Erlang/OTP'],
  escript: [null, 'Erlang/OTP'],
  gleam: [null, 'Gleam'],
  java: [null, 'a JDK'],
  z3: ['--solver', 'Z3'],
};

function remedy(command)
{
  const name = command
    .split(/[\\/]/)
    .at(-1)
    .replace(/\.(?:exe|cmd|bat|com)$/i, '')
    .toLowerCase();
  const [field, product] = advice[name] ?? [];
  if (!product) return `install ${command} or add its directory to PATH`;
  if (!field) return `install ${product} or add its directory to PATH`;
  if (field.startsWith('--'))
    return `pass ${field} <executable> or install ${product}`;
  return `set ${field} in lawspec.edn or install ${product}`;
}

// One line a person can act on, in place of `spawn mvn ENOENT`.
export function notFoundMessage(command, resolution)
{
  const extensions = resolution.extensions.filter(Boolean);
  const tried = extensions.length
    ? ` with the extensions ${extensions.join(' ')}`
    : '';
  if (resolution.explicit)
    return `${command} was not found; looked for ${resolution.searched.join(', ') || command}; ${remedy(command)}`;
  const where = resolution.directories.length
    ? `searched ${resolution.directories.join(', ')}`
    : 'PATH names no directory';
  return `${command} was not found on PATH; ${where}${tried}; ${remedy(command)}`;
}

// ASCII a batch argument may carry without quotes; every other ASCII
// character, and anything outside ASCII, forces quotes. `=`, `,`, `;` and
// spaces separate a batch file's parameters, so they are among the quoted.
const bare = /^[A-Za-z0-9#$*+\-./:?@\\_]+$/;

// One argument of a batch file's command line. Inside the quotes cmd reads
// & | < > ( ) ^ literally; a quote is doubled, so that the quotes cmd counts
// stay balanced however often the batch file's own lines are parsed, and the
// backslashes before a quote are doubled for the C runtime of the program
// that finally receives it. cmd expands %NAME% even inside quotes, so `%`
// is written `%%cd:~,%`: an empty substring of the always-defined `cd`, after
// a `%` that then pairs with nothing.
export function quoteBatchArgument(argument)
{
  const text = String(argument);
  const control = /[\r\n\0]/.exec(text);
  if (control)
    throw new UnsafeArgumentError(
      `an argument containing a ${control[0] === '\0' ? 'NUL' : 'line break'} cannot be passed to a Windows batch file: ${JSON.stringify(text)}`,
    );
  if (bare.test(text) && !text.endsWith('\\')) return text;
  let quoted = '"';
  let backslashes = 0;
  for (const unit of text)
  {
    if (unit === '\\') backslashes += 1;
    else
    {
      if (unit === '"') quoted += '\\'.repeat(backslashes) + '"';
      else if (unit === '%') quoted += '%%cd:~,';
      backslashes = 0;
    }
    quoted += unit;
  }
  return quoted + '\\'.repeat(backslashes) + '"';
}

// The text cmd.exe runs after /c: the batch file in quotes, then its
// arguments. /s makes cmd strip exactly the outer pair of quotes added by
// invocation.
export function batchCommandLine(script, args = [])
{
  const unusable = /["%\r\n\0]/.exec(script);
  if (unusable)
    throw new UnsafeArgumentError(
      `a batch file whose path contains ${JSON.stringify(unusable[0])} cannot be run safely through cmd.exe: ${script}`,
    );
  const line = [`"${script}"`, ...args.map(quoteBatchArgument)].join(' ');
  if (line.length + 2 > cmdLineLimit)
    throw new UnsafeArgumentError(
      `the command line for ${script} has ${line.length} characters; cmd.exe accepts at most ${cmdLineLimit - 2}`,
    );
  return line;
}

// What to hand to child_process for a command: {file, args, options}.
// Throws ToolNotFoundError on Windows when nothing matches; POSIX reports a
// missing command through the child's error, which describeSpawnError
// rewrites.
export function invocation(command, args = [], options = {}, host = {})
{
  const platform = host.platform ?? process.platform;
  if (platform !== 'win32' || options.shell)
    return {file: command, args, options};
  const env = options.env ?? host.env ?? process.env;
  const resolution = resolveCommand(command, {
    platform,
    env,
    cwd: String(options.cwd ?? host.cwd ?? process.cwd()),
    exists: host.exists ?? isFile,
  });
  if (!resolution.found) throw new ToolNotFoundError(command, resolution);
  if (!resolution.batch) return {file: resolution.file, args, options};
  return {
    file: environmentValue(env, 'ComSpec', platform) || 'cmd.exe',
    // /e:ON keeps the `cd` variable the percent encoding relies on; /v:OFF
    // keeps `!` literal; /d skips AutoRun commands.
    args: [
      '/e:ON',
      '/v:OFF',
      '/d',
      '/s',
      '/c',
      `"${batchCommandLine(resolution.file, args)}"`,
    ],
    options: {...options, windowsVerbatimArguments: true},
  };
}

// A missing command's ENOENT becomes a ToolNotFoundError. Every other error
// is returned as it is, including the ENOENT of a missing working directory
// or of a script whose interpreter is missing.
export function describeSpawnError(error, command, options = {})
{
  if (error?.code !== 'ENOENT' || error instanceof ToolNotFoundError)
    return error;
  const resolution = resolveCommand(command, {
    env: options.env ?? process.env,
    cwd: String(options.cwd ?? process.cwd()),
  });
  if (resolution.found) return error;
  const found = new ToolNotFoundError(command, resolution);
  found.cause = error;
  return found;
}

// child_process.spawn for a native tool. A missing command throws on Windows;
// pass the child's 'error' through describeSpawnError for POSIX.
export function spawnTool(command, args = [], options = {})
{
  const plan = invocation(command, args, options);
  return spawn(plan.file, plan.args, plan.options);
}

// Promisified child_process.execFile for a native tool: resolves
// {stdout, stderr}, and rejects with the error execFile reports, which
// carries stdout and stderr.
export function execTool(command, args = [], options = {})
{
  return new Promise((resolve, reject) =>
  {
    const plan = invocation(command, args, options);
    execFile(plan.file, plan.args, plan.options, (error, stdout, stderr) =>
    {
      if (!error) return resolve({stdout, stderr});
      reject(
        Object.assign(describeSpawnError(error, command, options), {
          stdout,
          stderr,
        }),
      );
    });
  });
}

// child_process.spawnSync for a native tool. A missing command is reported
// in the result's error, as spawnSync reports it.
export function spawnToolSync(command, args = [], options = {})
{
  let plan;
  try
  {
    plan = invocation(command, args, options);
  }
  catch (error)
  {
    return {
      error,
      status: null,
      signal: null,
      pid: 0,
      output: [null, '', ''],
      stdout: '',
      stderr: '',
    };
  }
  const result = spawnSync(plan.file, plan.args, plan.options);
  if (result.error)
    result.error = describeSpawnError(result.error, command, options);
  return result;
}

const plainWord = /^[\p{L}\p{N}_@+\-./:\\=]+$/u;

// Quoting for a command line shown to a person to paste into their shell.
// `quote` quotes one word; `inDirectory` wraps a command so that it runs in a
// directory without moving the person's shell there.
//
// POSIX: single quotes and a subshell. Windows: `cmd /d /s /c "cd /d <root>
// && <command>"`. When no word needs quotes that line is one double-quoted
// string without `$` or a backtick, which cmd and PowerShell both pass to
// cmd.exe unchanged. A word with a space or a cmd metacharacter is quoted
// inside it; that nested form is valid in cmd only, because PowerShell ends
// the string at the inner quote.
export function shellHint(platform = process.platform)
{
  if (platform !== 'win32')
  {
    const quote = value => "'" + String(value).replaceAll("'", "'\\''") + "'";
    return {
      quote,
      inDirectory: (root, command) => `(cd ${quote(root)} && ${command})`,
    };
  }
  const quote = value =>
    plainWord.test(String(value))
      ? String(value)
      : '"' + String(value).replaceAll('"', '""') + '"';
  return {
    quote,
    inDirectory: (root, command) =>
      `cmd /d /s /c "cd /d ${quote(root)} && ${command}"`,
  };
}
