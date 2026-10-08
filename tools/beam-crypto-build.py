#!/usr/bin/env python3
"""Exercise the native bridge builder, cache, failures and relocated loading.

ref:DEC-tests-cite-requirements ref:DEC-local-ci-only
"""
from pathlib import Path
import os
import shutil
import subprocess
import tempfile

root = Path(__file__).resolve().parent.parent
artifacts = root / '.artifacts'
artifacts.mkdir(exist_ok=True)

with tempfile.TemporaryDirectory(prefix="lawspec crypto ' $` ", dir=artifacts) as directory:
    project = Path(directory)
    (project / 'priv').mkdir()
    (project / 'ebin').mkdir()
    source = project / 'priv/lawspec_crypto_native.c'
    script = project / 'lawspec_crypto_build.escript'
    library = project / 'priv/lawspec_crypto_native.so'
    stamp = project / 'priv/lawspec_crypto_native.so.build'
    shutil.copy2(root / 'runtime/lawspec_crypto_native.c', source)
    shutil.copy2(root / 'runtime/lawspec_crypto_build.escript', script)

    def build(success=True, **environment):
        result = subprocess.run(['escript', str(script)], cwd=root,
                                env=dict(os.environ, **environment),
                                stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
        assert (result.returncode == 0) == success, result.stdout
        return result.stdout

    assert 'Built LawSpec crypto bridge' in build()
    first_mtime = library.stat().st_mtime_ns
    assert build() == ''
    assert library.stat().st_mtime_ns == first_mtime
    original = source.read_text()
    source.write_text(original + '\n/* Changed source input. */\n')
    assert 'Built LawSpec crypto bridge' in build()
    library.write_bytes(b'damaged output')
    assert 'Built LawSpec crypto bridge' in build()

    good_library, good_stamp = library.read_bytes(), stamp.read_bytes()
    source.write_text(original + '\n#error Deliberate compile failure\n')
    assert 'Deliberate compile failure' in build(success=False)
    assert library.read_bytes() == good_library
    assert stamp.read_bytes() == good_stamp
    assert not list((project / 'priv').glob('*.tmp'))
    assert 'headers missing' in build(success=False, LAWSPEC_OPENSSL_PREFIX=str(project / 'absent'))
    source.write_text(original)
    build()

    subprocess.run(['erlc', '-Werror', '-o', str(project / 'ebin'),
                    str(root / 'runtime/lawspec_beam_crypto_native.erl')], check=True)
    relocated = project / 'relocated application'
    shutil.copytree(project / 'ebin', relocated / 'ebin')
    shutil.copytree(project / 'priv', relocated / 'priv')
    (relocated / 'priv/lawspec_crypto_native.c').unlink()
    (relocated / 'priv/lawspec_crypto_native.so.build').unlink()
    expression = ('{Public, Private} = lawspec_beam_crypto_native:expand(mldsa65, <<0:256>>), '
                  '1952 = byte_size(Public), 4032 = byte_size(Private), halt().')
    subprocess.run(['erl', '-noshell', '-pa', str(relocated / 'ebin'), '-eval', expression],
                   cwd=relocated, env=dict(os.environ, CC='no-compiler-at-runtime',
                       ERL_CRASH_DUMP=str(project / 'erl_crash.dump')), check=True)

print('BEAM crypto builder: cache, changed inputs, damaged output, failed builds, quoted paths and relocated loading passed.')
