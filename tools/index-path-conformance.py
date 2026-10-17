#!/usr/bin/env python3
"""Exercise mandatory nested index guards in each shared native runtime.

This checks runtime enforcement, independently of law verification or witness
search. It does not certify source migration or dependent record descriptors.
ref:DEC-typed-core-boundary ref:DEC-indexed-families-as-evidence
"""
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]
FIXTURES = ROOT / 'test/fixtures/index-paths'
ALIASES = {
    'typescript': 'javascript', 'kotlin': 'java', 'scala': 'java',
    'groovy': 'java', 'clojure': 'java', 'csharp': 'fsharp',
    'elixir': 'erlang', 'gleam': 'erlang',
}

def run(*args, cwd=ROOT):
    subprocess.run([str(arg) for arg in args], cwd=cwd, check=True)

def main():
    if len(sys.argv) != 2:
        raise SystemExit('usage: index-path-conformance.py TARGET')
    target = sys.argv[1]
    runtime = ALIASES.get(target, target)
    artifacts = ROOT / '.artifacts/index-path-conformance'
    artifacts.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix=target + '-', dir=artifacts) as folder:
        work = Path(folder)
        if runtime == 'javascript':
            run('node', '--test', FIXTURES / 'web.mjs')
        elif runtime == 'python':
            python = os.environ.get('LAWSPEC_PYTHON', str(ROOT / '.integration/python/.venv/bin/python'))
            run(python, '-B', FIXTURES / 'python.py')
        elif runtime == 'java':
            run('javac', '-d', work, ROOT / 'runtime/LawSpecRuntime.java',
                ROOT / 'runtime/LawSpecSchema.java', FIXTURES / 'IndexPaths.java')
            run('java', '-cp', work, 'IndexPaths')
        elif runtime == 'haskell':
            run('stack', 'exec', '--', 'runghc', '-iruntime', FIXTURES / 'IndexPaths.hs')
        elif runtime == 'go':
            for source in (ROOT / 'runtime').glob('lawspec_*.go'):
                (work / source.name).write_text(source.read_text().replace('package RUNTIME_PACKAGE', 'package indexpaths'))
            shutil.copy2(FIXTURES / 'index_paths_test.go', work)
            (work / 'go.mod').write_text('module indexpaths\n\ngo 1.25.0\n\nrequire (\n'
                ' github.com/cloudflare/circl v1.6.5\n pgregory.net/rapid v1.2.0\n)\n\nrequire (\n'
                ' golang.org/x/crypto v0.54.0 // indirect\n golang.org/x/sys v0.47.0 // indirect\n)\n')
            shutil.copy2(ROOT / 'test/locks/go/go.sum', work / 'go.sum')
            run('go', 'test', '-mod=readonly', './...', cwd=work)
        elif runtime == 'rust':
            run('cargo', 'test', '--manifest-path', ROOT / 'runtime/rust/Cargo.toml', '--locked')
        elif runtime == 'swift':
            run('swiftc', '-o', work / 'index-paths',
                *sorted((ROOT / 'runtime/swift/LawSpecRuntime').glob('*.swift')), FIXTURES / 'main.swift')
            run(work / 'index-paths')
        elif runtime == 'fsharp':
            from xml.sax.saxutils import quoteattr
            # C# and F# checks can run concurrently: each compiles its own copy.
            library = work / 'runtime'
            shutil.copytree(ROOT / 'runtime/dotnet/LawSpec.Runtime', library,
                ignore=shutil.ignore_patterns('bin', 'obj'))
            (work / 'IndexPaths.fsproj').write_text(
                '<Project Sdk="Microsoft.NET.Sdk"><PropertyGroup><OutputType>Exe</OutputType>'
                '<TargetFramework>net10.0</TargetFramework></PropertyGroup><ItemGroup>'
                f'<Compile Include={quoteattr(str(FIXTURES / "IndexPaths.fs"))}/>'
                f'<ProjectReference Include={quoteattr(str(library / "LawSpec.Runtime.fsproj"))}/>'
                '</ItemGroup></Project>')
            run('dotnet', 'run', '--project', work / 'IndexPaths.fsproj')
        elif runtime == 'erlang':
            run('erlc', '-Werror', '-o', work,
                *sorted((ROOT / 'runtime').glob('lawspec_beam_*.erl')),
                ROOT / 'runtime/lawspec_network.erl', ROOT / 'test/fixtures/beam/lawspec_beam_schema_tests.erl')
            run('erl', '-noshell', '-pa', work, '-eval',
                'case eunit:test(lawspec_beam_schema_tests, [verbose]) of ok -> halt(0); _ -> halt(1) end.')
        else:
            raise SystemExit('unsupported target: ' + target)
    print(f'index paths: {target} uses {runtime}; passed', flush=True)

if __name__ == '__main__':
    main()
