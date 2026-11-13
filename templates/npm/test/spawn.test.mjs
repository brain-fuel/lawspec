// The Windows cases run on every platform: resolution takes its platform,
// environment and file system as arguments, and the quoting is text. Nothing
// here starts cmd.exe; the last tests start real processes on this host.
import assert from 'node:assert/strict';
import {test} from 'node:test';
import {mkdtemp, rm} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import path from 'node:path';
import {
  ToolNotFoundError,
  UnsafeArgumentError,
  batchCommandLine,
  describeSpawnError,
  environmentValue,
  execTool,
  invocation,
  notFoundMessage,
  quoteBatchArgument,
  resolveCommand,
  shellHint,
  spawnTool,
  spawnToolSync,
} from '../spawn.mjs';

// A Windows host with the given files; names compare without case, as NTFS
// does.
function windows(files, env = {}, cwd = 'C:\\work\\shop')
{
  const present = new Set(files.map(file => file.toLowerCase()));
  return {
    platform: 'win32',
    cwd,
    env: {
      Path: 'C:\\tools\\maven\\bin;C:\\Program Files\\nodejs;C:\\go\\bin',
      PATHEXT: '.com;.exe;.bat;.cmd',
      ComSpec: 'C:\\Windows\\System32\\cmd.exe',
      ...env,
    },
    exists: file => present.has(file.toLowerCase()),
  };
}
const tools = [
  'C:\\tools\\maven\\bin\\mvn',
  'C:\\tools\\maven\\bin\\mvn.cmd',
  'C:\\Program Files\\nodejs\\node.exe',
  'C:\\Program Files\\nodejs\\npm',
  'C:\\Program Files\\nodejs\\npm.cmd',
  'C:\\Program Files\\nodejs\\npx.cmd',
  'C:\\go\\bin\\go.exe',
  'C:\\work\\shop\\gradlew',
  'C:\\work\\shop\\gradlew.bat',
  'C:\\elixir\\bin\\mix.bat',
];

test('win32 resolution applies PATHEXT in PATH order', () =>
{
  const cases = [
    ['mvn', 'C:\\tools\\maven\\bin\\mvn.cmd', true],
    ['mvn.cmd', 'C:\\tools\\maven\\bin\\mvn.cmd', true],
    ['MVN.CMD', 'C:\\tools\\maven\\bin\\MVN.CMD', true],
    ['npm', 'C:\\Program Files\\nodejs\\npm.cmd', true],
    ['npx', 'C:\\Program Files\\nodejs\\npx.cmd', true],
    ['node', 'C:\\Program Files\\nodejs\\node.exe', false],
    ['node.exe', 'C:\\Program Files\\nodejs\\node.exe', false],
    ['go', 'C:\\go\\bin\\go.exe', false],
    // The working directory comes first, and the extensionless shell script
    // beside the batch file is never chosen.
    ['gradlew', 'C:\\work\\shop\\gradlew.bat', true],
    ['C:\\work\\shop\\gradlew.bat', 'C:\\work\\shop\\gradlew.bat', true],
    ['C:\\work\\shop\\gradlew', 'C:\\work\\shop\\gradlew.bat', true],
    ['.\\gradlew', 'C:\\work\\shop\\gradlew.bat', true],
    ['./gradlew.bat', 'C:\\work\\shop\\gradlew.bat', true],
    ['C:/tools/maven/bin/mvn', 'C:\\tools\\maven\\bin\\mvn.cmd', true],
    ['C:\\elixir\\bin\\mix', 'C:\\elixir\\bin\\mix.bat', true],
  ];
  for (const [command, file, batch] of cases)
    assert.deepEqual(
      resolveCommand(command, windows(tools)),
      {found: true, file, batch},
      command,
    );
});

test('win32 resolution honours PATHEXT order, quoted PATH entries and PATH spelling', () =>
{
  const both = ['C:\\bin\\tool.exe', 'C:\\bin\\tool.cmd'];
  assert.equal(
    resolveCommand('tool', windows(both, {Path: 'C:\\bin'})).file,
    'C:\\bin\\tool.exe',
  );
  assert.equal(
    resolveCommand(
      'tool',
      windows(both, {Path: 'C:\\bin', PATHEXT: '.CMD;.EXE'}),
    ).file,
    'C:\\bin\\tool.CMD',
  );
  assert.equal(
    resolveCommand(
      'npm',
      windows(tools, {Path: 'C:\\go\\bin;"C:\\Program Files\\nodejs";'}),
    ).file,
    'C:\\Program Files\\nodejs\\npm.cmd',
  );
  // PATH under another spelling, and no PATHEXT at all.
  const host = windows(tools);
  host.env = {PATH: 'C:\\tools\\maven\\bin'};
  assert.equal(
    resolveCommand('mvn', host).file,
    'C:\\tools\\maven\\bin\\mvn.CMD',
  );
  assert.equal(environmentValue({Path: 'a'}, 'PATH', 'win32'), 'a');
  assert.equal(environmentValue({Path: 'a'}, 'PATH', 'linux'), undefined);
  // A relative PATH entry is relative to the working directory.
  assert.equal(
    resolveCommand(
      'mvn',
      windows(['C:\\work\\shop\\bin\\mvn.cmd'], {Path: 'bin'}),
    ).file,
    'C:\\work\\shop\\bin\\mvn.cmd',
  );
});

test('win32 resolution skips the working directory when the user disabled it', () =>
{
  const files = ['C:\\work\\shop\\mvn.cmd', 'C:\\tools\\maven\\bin\\mvn.cmd'];
  assert.equal(
    resolveCommand('mvn', windows(files)).file,
    'C:\\work\\shop\\mvn.cmd',
  );
  assert.equal(
    resolveCommand(
      'mvn',
      windows(files, {NoDefaultCurrentDirectoryInExePath: '1'}),
    ).file,
    'C:\\tools\\maven\\bin\\mvn.cmd',
  );
});

test('a missing win32 command lists what was searched', () =>
{
  const missing = resolveCommand(
    'mvn',
    windows([], {Path: 'C:\\a;C:\\b', PATHEXT: '.EXE;.CMD'}),
  );
  assert.deepEqual(missing, {
    found: false,
    explicit: false,
    directories: ['C:\\work\\shop', 'C:\\a', 'C:\\b'],
    extensions: ['.EXE', '.CMD'],
    searched: [
      'C:\\work\\shop\\mvn.EXE',
      'C:\\work\\shop\\mvn.CMD',
      'C:\\a\\mvn.EXE',
      'C:\\a\\mvn.CMD',
      'C:\\b\\mvn.EXE',
      'C:\\b\\mvn.CMD',
    ],
  });
  assert.equal(
    notFoundMessage('mvn', missing),
    'mvn was not found on PATH; searched C:\\work\\shop, C:\\a, C:\\b with the extensions .EXE .CMD; set :maven in lawspec.edn or install Maven',
  );
  const explicit = resolveCommand(
    'C:\\tools\\mvn.cmd',
    windows([], {PATHEXT: '.EXE'}),
  );
  assert.deepEqual(explicit.searched, [
    'C:\\tools\\mvn.cmd',
    'C:\\tools\\mvn.cmd.EXE',
  ]);
  assert.equal(
    notFoundMessage('C:\\tools\\mvn.cmd', explicit),
    'C:\\tools\\mvn.cmd was not found; looked for C:\\tools\\mvn.cmd, C:\\tools\\mvn.cmd.EXE; set :maven in lawspec.edn or install Maven',
  );
});

test('the not-found message names the manifest field or the product', () =>
{
  const posix = {
    platform: 'linux',
    env: {PATH: '/usr/bin:/opt/bin'},
    cwd: '/work',
    exists: () => false,
  };
  const message = command =>
    notFoundMessage(command, resolveCommand(command, posix));
  assert.equal(
    message('gradle'),
    'gradle was not found on PATH; searched /usr/bin, /opt/bin; set :gradle in lawspec.edn or install Gradle',
  );
  assert.match(
    message('python3'),
    /; set :python in lawspec\.edn or install Python$/,
  );
  assert.match(
    message('npx'),
    /; install Node\.js or add its directory to PATH$/,
  );
  assert.match(message('z3'), /; pass --solver <executable> or install Z3$/);
  assert.match(
    message('frobnicate'),
    /; install frobnicate or add its directory to PATH$/,
  );
  assert.equal(
    message('./gradlew'),
    './gradlew was not found; looked for /work/gradlew; set :gradle in lawspec.edn or install Gradle',
  );
  assert.equal(
    notFoundMessage('mvn', resolveCommand('mvn', {...posix, env: {}})),
    'mvn was not found on PATH; searched /work; set :maven in lawspec.edn or install Maven',
  );
});

test('posix resolution searches PATH and resolves explicit paths', () =>
{
  const host = {
    platform: 'linux',
    env: {PATH: '/usr/bin::/opt/bin'},
    cwd: '/work',
    exists: file => ['/opt/bin/mvn', '/work/gradlew'].includes(file),
  };
  assert.deepEqual(resolveCommand('mvn', host), {
    found: true,
    file: '/opt/bin/mvn',
    batch: false,
  });
  assert.equal(resolveCommand('./gradlew', host).file, '/work/gradlew');
  // An empty entry is the working directory.
  assert.equal(resolveCommand('gradlew', host).file, '/work/gradlew');
  assert.equal(resolveCommand('mvn.cmd', host).found, false);
});

// Each row: the argument, and its text on a batch file's command line.
const quoting = [
  ['test', 'test'],
  ['--no-daemon', '--no-daemon'],
  ['C:\\work\\shop\\pom.xml', 'C:\\work\\shop\\pom.xml'],
  ['src/test/*.mjs', 'src/test/*.mjs'],
  ['', '""'],
  ['two words', '"two words"'],
  ['tab\there', '"tab\there"'],
  // cmd splits a batch file's parameters at these.
  ['-Dtest=Shop#law', '"-Dtest=Shop#law"'],
  ['a,b', '"a,b"'],
  ['a;b', '"a;b"'],
  // Command separators, redirection, grouping and the escape character.
  ['a&b', '"a&b"'],
  ['a&&calc', '"a&&calc"'],
  ['a|b', '"a|b"'],
  ['a||b', '"a||b"'],
  ['a<b', '"a<b"'],
  ['a>b', '"a>b"'],
  ['2>&1', '"2>&1"'],
  ['(a)', '"(a)"'],
  ['a^b', '"a^b"'],
  ['^', '"^"'],
  ['a!b', '"a!b"'],
  ['!PATH!', '"!PATH!"'],
  ['`a`', '"`a`"'],
  ["it's", '"it\'s"'],
  ['~', '"~"'],
  ['[a]', '"[a]"'],
  ['{a}', '"{a}"'],
  // Percent expansion happens inside quotes too.
  ['100%', '"100%%cd:~,%"'],
  ['%PATH%', '"%%cd:~,%PATH%%cd:~,%"'],
  ['%%', '"%%cd:~,%%%cd:~,%"'],
  ['%1', '"%%cd:~,%1"'],
  // Quotes are doubled; backslashes are doubled only before a quote and at
  // the end.
  ['say "hi"', '"say ""hi"""'],
  ['"', '""""'],
  ['" & calc & "', '""" & calc & """'],
  ['"&calc', '"""&calc"'],
  ['a\\"b', '"a\\\\""b"'],
  ['a\\\\"b', '"a\\\\\\\\""b"'],
  ['C:\\dir\\', '"C:\\dir\\\\"'],
  ['C:\\my dir\\', '"C:\\my dir\\\\"'],
  ['\\\\', '"\\\\\\\\"'],
  ['a\\b c', '"a\\b c"'],
  ['\\\\server\\share\\x', '\\\\server\\share\\x'],
  ['^"&calc', '"^""&calc"'],
  ['%CMDCMDLINE:~-1%&calc', '"%%cd:~,%CMDCMDLINE:~-1%%cd:~,%&calc"'],
  ['caf\u00e9', '"caf\u00e9"'],
  ['\u65e5\u672c', '"\u65e5\u672c"'],
  ['bell\u0007', '"bell\u0007"'],
];

test('batch arguments are quoted as cmd.exe reads them', () =>
{
  for (const [argument, expected] of quoting)
    assert.equal(quoteBatchArgument(argument), expected, argument);
  assert.equal(quoteBatchArgument(42), '42');
});

// A model of the two readers of a batch command line, written from their
// documentation and independent of the quoting code. cmd.exe, at a command
// prompt: `%name%` expands when the name is defined (cd is always defined;
// `:~,` takes an empty substring), any other `%` stays; then a quote toggles
// quoting, and outside quotes ^ & | < > ( ) are syntax.
function cmdExpand(line, variables)
{
  let out = '';
  for (let i = 0; i < line.length; i++)
  {
    if (line[i] !== '%')
    {
      out += line[i];
      continue;
    }
    const close = line.indexOf('%', i + 1);
    const name = close < 0 ? '' : line.slice(i + 1, close);
    const variable = name.split(':')[0].toLowerCase();
    if (name && variable in variables)
    {
      out += name.includes(':~,') ? '' : variables[variable];
      i = close;
    }
    else out += '%';
  }
  return out;
}
function cmdSyntaxOutsideQuotes(line)
{
  let quoted = false;
  const found = [];
  for (const unit of line)
  {
    if (unit === '"') quoted = !quoted;
    else if (!quoted && '^&|<>()\r\n'.includes(unit)) found.push(unit);
  }
  return {found, quoted};
}
// The Microsoft C runtime's argument rules (2008 and later): 2n backslashes
// and a quote give n backslashes and a delimiter, 2n+1 give n and a literal
// quote, and a doubled quote inside quotes is one literal quote.
function runtimeArguments(line)
{
  const args = [];
  let i = 0;
  while (i < line.length)
  {
    while (line[i] === ' ' || line[i] === '\t') i++;
    if (i >= line.length) break;
    let arg = '';
    let quoted = false;
    for (; i < line.length; i++)
    {
      const unit = line[i];
      if (!quoted && (unit === ' ' || unit === '\t')) break;
      if (unit === '\\')
      {
        let count = 0;
        while (line[i] === '\\')
        {
          count++;
          i++;
        }
        if (line[i] === '"')
        {
          arg += '\\'.repeat(Math.floor(count / 2));
          if (count % 2) arg += '"';
          else i--;
        }
        else
        {
          arg += '\\'.repeat(count);
          i--;
        }
      }
      else if (unit === '"')
      {
        if (quoted && line[i + 1] === '"')
        {
          arg += '"';
          i++;
        }
        else quoted = !quoted;
      }
      else arg += unit;
    }
    args.push(arg);
  }
  return args;
}

test('a quoted batch command line survives cmd.exe and the C runtime unchanged', () =>
{
  const variables = {
    cd: 'C:\\work\\shop',
    path: 'C:\\evil" & calc & "',
    cmdcmdline: 'cmd /c "x" & calc',
    1: 'one',
  };
  const script = 'C:\\Program Files\\maven\\bin\\mvn.cmd';
  const all = quoting.map(([argument]) => argument);
  // Each argument alone, every adjacent pair, and all of them together.
  const lists = [
    ...all.map(argument => [argument]),
    ...all.slice(1).map((argument, index) => [all[index], argument]),
    all,
  ];
  for (const args of lists)
  {
    const line = batchCommandLine(script, args);
    const expanded = cmdExpand(line, variables);
    // Parsing it again, as a batch file forwarding %* does, changes nothing
    // that matters: it is still inside quotes wherever syntax occurs.
    for (const text of [line, expanded])
      assert.deepEqual(
        cmdSyntaxOutsideQuotes(text),
        {found: [], quoted: false},
        text,
      );
    assert.deepEqual(
      runtimeArguments(expanded),
      [script, ...args.map(String)],
      line,
    );
  }
});

test('arguments cmd.exe cannot carry are refused', () =>
{
  for (const argument of ['a\nb', 'a\r\nb', 'a\rb', 'a\0b', '\n'])
    assert.throws(
      () => quoteBatchArgument(argument),
      error =>
        error instanceof UnsafeArgumentError &&
        error.code === 'LAWSPEC_UNSAFE_ARGUMENT' &&
        /cannot be passed to a Windows batch file/.test(error.message),
      JSON.stringify(argument),
    );
  for (const script of [
    'C:\\a"b\\mvn.cmd',
    'C:\\100%\\mvn.cmd',
    'C:\\a\nb\\mvn.cmd',
  ])
    assert.throws(
      () => batchCommandLine(script, []),
      error =>
        error instanceof UnsafeArgumentError &&
        /cannot be run safely through cmd\.exe/.test(error.message),
      script,
    );
  assert.throws(
    () => batchCommandLine('C:\\mvn.cmd', ['x'.repeat(8200)]),
    /cmd\.exe accepts at most 8189/,
  );
  assert.equal(
    batchCommandLine('C:\\a & b\\mvn.cmd', ['test']),
    '"C:\\a & b\\mvn.cmd" test',
  );
});

test('win32 invocation runs batch files through cmd.exe and executables directly', () =>
{
  const host = windows(tools);
  const options = {cwd: 'C:\\work\\shop', stdio: 'ignore'};
  assert.deepEqual(
    invocation('mvn', ['-q', '-Dtest=Shop Law', 'test'], options, host),
    {
      file: 'C:\\Windows\\System32\\cmd.exe',
      args: [
        '/e:ON',
        '/v:OFF',
        '/d',
        '/s',
        '/c',
        '""C:\\tools\\maven\\bin\\mvn.cmd" -q "-Dtest=Shop Law" test"',
      ],
      options: {...options, windowsVerbatimArguments: true},
    },
  );
  // An explicit override, by name and by path.
  for (const command of ['mvn.cmd', 'C:\\tools\\maven\\bin\\mvn.cmd'])
    assert.equal(
      invocation(command, ['test'], options, host).args.at(-1),
      '""C:\\tools\\maven\\bin\\mvn.cmd" test"',
    );
  assert.equal(
    invocation('gradlew', ['test'], options, host).args.at(-1),
    '""C:\\work\\shop\\gradlew.bat" test"',
  );
  // An executable keeps its arguments as an array for Node to quote.
  const nasty = ['-e', 'a "b" & c %PATH%'];
  assert.deepEqual(invocation('node', nasty, options, host), {
    file: 'C:\\Program Files\\nodejs\\node.exe',
    args: nasty,
    options,
  });
  // The child's own environment and working directory decide.
  const elsewhere = {
    cwd: 'C:\\other',
    env: {PATH: 'C:\\elixir\\bin', PATHEXT: '.BAT'},
  };
  const mix = invocation('mix', ['test'], elsewhere, host);
  assert.equal(mix.file, 'cmd.exe');
  assert.equal(mix.args.at(-1), '""C:\\elixir\\bin\\mix.BAT" test"');
  assert.throws(
    () => invocation('gradlew', [], elsewhere, host),
    ToolNotFoundError,
  );
});

test('win32 invocation fails before starting anything it cannot name or quote', () =>
{
  const host = windows(tools);
  assert.throws(
    () => invocation('gradle', ['test'], {}, host),
    error =>
      error instanceof ToolNotFoundError &&
      error.code === 'ENOENT' &&
      error.command === 'gradle' &&
      error.searched.includes('C:\\go\\bin\\gradle.cmd') &&
      /^gradle was not found on PATH; searched C:\\work\\shop, C:\\tools\\maven\\bin, .*; set :gradle in lawspec\.edn or install Gradle$/.test(
        error.message,
      ),
  );
  assert.throws(
    () => invocation('mvn', ['-Dnote=a\nb'], {}, host),
    UnsafeArgumentError,
  );
  // An executable takes the same argument: Node quotes it for CreateProcess.
  assert.deepEqual(invocation('go', ['a\nb'], {}, host).args, ['a\nb']);
});

test('posix invocation is the command as given', () =>
{
  const args = ['a b', '"', '%PATH%'];
  const options = {cwd: '/work', env: {PATH: '/nowhere'}};
  const plan = invocation('mvn', args, options, {
    platform: 'linux',
    exists: () => false,
  });
  assert.equal(plan.file, 'mvn');
  assert.equal(plan.args, args);
  assert.equal(plan.options, options);
});

test('the test hint is quoted for the shell it is printed for', () =>
{
  const posix = shellHint('linux');
  assert.equal(posix.quote("it's here"), "'it'\\''s here'");
  assert.equal(
    posix.inDirectory('/work/my shop', `${posix.quote('mvn')} test`),
    "(cd '/work/my shop' && 'mvn' test)",
  );
  const win = shellHint('win32');
  // No word needs quotes: one line for cmd and PowerShell.
  assert.equal(
    win.inDirectory('C:\\work\\shop', `${win.quote('mvn')} test`),
    'cmd /d /s /c "cd /d C:\\work\\shop && mvn test"',
  );
  assert.equal(
    win.quote('C:\\Users\\Jos\u00e9\\shop'),
    'C:\\Users\\Jos\u00e9\\shop',
  );
  // A word that needs quotes: the cmd form.
  assert.equal(
    win.inDirectory(
      'C:\\my work\\shop',
      `${win.quote('C:\\Program Files\\maven\\bin\\mvn.cmd')} test`,
    ),
    'cmd /d /s /c "cd /d "C:\\my work\\shop" && "C:\\Program Files\\maven\\bin\\mvn.cmd" test"',
  );
  for (const word of ['a&b', 'a b', '$HOME', 'a`b', "a'b", 'a(b)', 'a%b', ''])
    assert.equal(win.quote(word), `"${word}"`, word);
});

// From here on real processes are started, on this host only.
const missing = 'lawspec-no-such-tool-4f1c';

test('a missing command is a finding, not ENOENT, through every entry point', async () =>
{
  const expected = error =>
    error instanceof ToolNotFoundError &&
    error.code === 'ENOENT' &&
    error.message.startsWith(`${missing} was not found on PATH; searched `) &&
    error.message.endsWith(
      `; install ${missing} or add its directory to PATH`,
    ) &&
    !/spawn .* ENOENT/.test(error.message);
  await assert.rejects(execTool(missing, ['--version']), expected);
  const sync = spawnToolSync(missing, ['--version']);
  assert.ok(expected(sync.error));
  assert.equal(sync.status, null);
  const emitted = await new Promise((resolve, reject) =>
  {
    try
    {
      const child = spawnTool(missing, []);
      child.on('error', error => resolve(describeSpawnError(error, missing)));
      child.on('close', () => reject(new Error('started')));
    }
    catch (error)
    {
      resolve(error);
    }
  });
  assert.ok(expected(emitted));
});

test('other spawn failures keep their own error', async t =>
{
  const root = await mkdtemp(path.join(tmpdir(), 'lawspec-spawn-'));
  t.after(() => rm(root, {recursive: true, force: true}));
  // A working directory that does not exist is also ENOENT.
  const options = {cwd: path.join(root, 'absent')};
  await assert.rejects(
    execTool(process.execPath, ['--version'], options),
    error => !(error instanceof ToolNotFoundError) && error.code === 'ENOENT',
  );
  const failed = Object.assign(new Error('boom'), {code: 'EACCES'});
  assert.equal(describeSpawnError(failed, missing), failed);
  // A command that runs and fails reports its exit code and output.
  await assert.rejects(
    execTool(process.execPath, [
      '-e',
      'console.log("out"); console.error("err"); process.exit(3)',
    ]),
    error =>
      error.code === 3 && error.stdout === 'out\n' && error.stderr === 'err\n',
  );
});

test('arguments reach a real process unchanged', async () =>
{
  const args = quoting.map(([argument]) => argument).concat(['a\nb']);
  const script = 'process.stdout.write(JSON.stringify(process.argv.slice(1)))';
  const {stdout} = await execTool(process.execPath, ['-e', script, ...args], {
    encoding: 'utf8',
  });
  assert.deepEqual(JSON.parse(stdout), args);
  const sync = spawnToolSync(process.execPath, ['-e', script, ...args], {
    encoding: 'utf8',
  });
  assert.deepEqual(JSON.parse(sync.stdout), args);
  const streamed = await new Promise((resolve, reject) =>
  {
    const child = spawnTool(process.execPath, ['-e', script, ...args], {
      stdio: ['ignore', 'pipe', 'inherit'],
    });
    let text = '';
    child.stdout.on('data', chunk => (text += chunk));
    child.on('error', reject);
    child.on('close', code => resolve({code, text}));
  });
  assert.equal(streamed.code, 0);
  assert.deepEqual(JSON.parse(streamed.text), args);
});
