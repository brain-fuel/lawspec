#!/usr/bin/env python3
"""Validate emitted artifacts with independent tools, including rejection controls.

Run with LAWSPEC_NATIVE_CORE pointing at the current native compiler, Python
jsonschema/PyYAML, OpenTofu, JDK and ANTLR_JAR (ANTLR 4.13.2) available.
ref:REQ-artifact-targets ref:DEC-artifact-targets
"""

import copy
import argparse
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile

import jsonschema
import yaml


SOURCE = (Path(__file__).resolve().parents[1] / 'test/fixtures/artifact-configuration.lawspec').read_text()
EXPECTED = dict(port=8080, enabled=True, hosts=['localhost', '${literal}', '%{literal}', '日本語 é 😀'])


def run(args, directory, *, ok=True, env=None):
    result = subprocess.run(args, cwd=directory, text=True, capture_output=True, env=env)
    if (result.returncode == 0) != ok:
        raise AssertionError(f'{args} exited {result.returncode}\n{result.stdout}\n{result.stderr}')
    return result


def compile_artifact(core, target, source):
    request = dict(schemaVersion=5, languageProfile='1.0-rc.2',
                   verification=dict(layers=[]), method='planGeneration',
                   sources=[dict(path='configuration.lawspec', content=source)], target=target)
    result = subprocess.run([core], input=json.dumps(request) + '\n', text=True,
                            capture_output=True, check=True)
    response = json.loads(result.stdout)
    return response


def generate(core, directory, target, source=SOURCE):
    response = compile_artifact(core, target, source)
    assert not response['diagnostics'], response['diagnostics']
    assert not response.get('tests'), 'artifacts must not claim native law tests'
    directory.mkdir()
    for artifact in response['files']:
        destination = directory / artifact['path']
        destination.parent.mkdir(parents=True, exist_ok=True)
        destination.write_text(artifact['content'])
    return response


def canon_parse(directory, language, start, filename):
    """Optionally check the same bytes with canon's independent grammar reader."""
    binary = os.environ.get('CANON_BINARY')
    if not binary:
        return
    repository = Path(os.environ['CANON_REPO']).resolve()
    grammar = repository / 'grammars' / language / 'canonically_commented'
    lexer, parser = dict(hcl=('HCLLexer.g4', 'HCLParser.g4'),
                         yaml=('YAMLLexer.g4', 'YAMLParser.g4'),
                         antlr4=('ANTLRv4Lexer.g4', 'ANTLRv4Parser.g4'),
                         make=('MakefileLexer.g4', 'MakefileParser.g4'))[language]
    run([str(Path(binary).resolve()), 'parse', str(grammar / lexer),
         str(grammar / parser), start, filename], directory)


def check_yaml(core, directory):
    generate(core, directory, 'yaml')
    schema = json.loads((directory / 'configuration.schema.json').read_text())
    config = yaml.safe_load((directory / 'configuration.yaml').read_text())
    jsonschema.Draft202012Validator.check_schema(schema)
    validate = jsonschema.Draft202012Validator(schema).validate
    validate(config)
    canon_parse(directory, 'yaml', 'yamlFile', 'configuration.yaml')
    name, settings = next(iter(config.items()))
    assert settings == EXPECTED
    for wrong in (-1, 65536, 0.5, None, '8080'):
        mutant = copy.deepcopy(config)
        mutant[name]['port'] = wrong
        try:
            validate(mutant)
        except jsonschema.ValidationError:
            pass
        else:
            raise AssertionError(f'schema accepted invalid port {wrong!r}')
    mutant = copy.deepcopy(config)
    mutant[name]['surprise'] = True
    try:
        validate(mutant)
    except jsonschema.ValidationError:
        pass
    else:
        raise AssertionError('schema accepted an undeclared field')
    return settings


def check_hcl(core, directory, expected):
    generate(core, directory, 'hcl')
    receipt = json.loads((directory / 'lawspec-artifacts.json').read_text())
    name = receipt['entries'][0]['name']
    (directory / 'outputs.tf').write_text(f'output "settings" {{ value = var.{name} }}\n')
    tofu = shutil.which('tofu')
    assert tofu, 'OpenTofu is required'
    run([tofu, 'init', '-backend=false', '-input=false'], directory)
    run([tofu, 'validate', '-no-color'], directory)
    canon_parse(directory, 'hcl', 'configFile', 'variables.tf')
    args = [tofu, 'plan', '-no-color', '-input=false', '-refresh=false', '-lock=false',
            '-var-file=configuration.tfvars.json']
    run(args + ['-out=plan'], directory)
    plan = json.loads(run([tofu, 'show', '-json', 'plan'], directory).stdout)
    assert plan['planned_values']['outputs']['settings']['value'] == expected, 'Terraform changed literal data'
    values = json.loads((directory / 'configuration.tfvars.json').read_text())
    for wrong in (-1, 65536, 0.5, None):
        mutant = copy.deepcopy(values)
        mutant[name]['port'] = wrong
        (directory / 'configuration.tfvars.json').write_text(json.dumps(mutant))
        run(args, directory, ok=False)


def check_empty_type(core, directory):
    generate(core, directory, 'yaml', 'unit empty\ntype Empty is one of end type\nend unit')
    schema = json.loads((directory / 'configuration.schema.json').read_text())
    jsonschema.Draft202012Validator.check_schema(schema)
    empty_schema, = schema['$defs'].values()
    validator = jsonschema.Draft202012Validator(empty_schema)
    for value in (None, False, 0, '', [], {}):
        assert list(validator.iter_errors(value)), 'an empty type acquired a configuration inhabitant'


def check_large_integer(core, directory):
    expected = 2**4096 + 17
    generate(core, directory, 'yaml',
             f'unit exact\nfunction value (u :: Unit) -> Integer is {expected} end function\nend unit')
    config = yaml.safe_load((directory / 'configuration.yaml').read_text())
    assert list(config.values()) == [expected], 'unbounded integer configuration lost precision'


def check_hcl_type_export(core, directory):
    generate(core, directory, 'hcl', 'unit types\ntype Settings is a record{port :: UInt16} end type\nend unit')
    receipt = json.loads((directory / 'lawspec-artifacts.json').read_text())
    variable, = receipt['typeVariables']
    assert receipt['configurationComplete'] is False
    assert receipt['missingTypeValues'] == [variable['name']]
    assert 'types::type::Settings' in receipt['types'][variable['schema']]
    (directory / 'outputs.tf').write_text(f'output "settings" {{ value = var.{variable["name"]} }}\n')
    (directory / 'inputs.tfvars.json').write_text(json.dumps({variable['name']: {'port': 8080}}))
    tofu = shutil.which('tofu')
    run([tofu, 'init', '-backend=false', '-input=false'], directory)
    run([tofu, 'plan', '-input=false', '-refresh=false', '-lock=false', '-var-file=inputs.tfvars.json'], directory)


def check_restrictions(core, directory, target):
    source = ('unit restricted\ntype Positive is a record{value :: (x :: UInt16 where x > 0)} end type\n'
              'function sample (u :: Unit) -> Positive is Positive record{value = 1} end function\nend unit')
    generate(core, directory, target, source)
    if target == 'yaml':
        schema = json.loads((directory / 'configuration.schema.json').read_text())
        config = yaml.safe_load((directory / 'configuration.yaml').read_text())
        validator = jsonschema.Draft202012Validator(schema)
        validator.validate(config)
        config['restricted::sample']['value'] = 0
        assert list(validator.iter_errors(config)), 'schema dropped the constructor predicate'
    else:
        values = json.loads((directory / 'configuration.tfvars.json').read_text())
        name, = values
        (directory / 'outputs.tf').write_text(f'output "sample" {{ value = var.{name} }}\n')
        tofu = shutil.which('tofu')
        run([tofu, 'init', '-backend=false', '-input=false'], directory)
        args = [tofu, 'plan', '-input=false', '-refresh=false', '-lock=false', '-var-file=configuration.tfvars.json']
        run(args, directory)
        values[name]['value'] = 0
        (directory / 'configuration.tfvars.json').write_text(json.dumps(values))
        run(args, directory, ok=False)


def check_sum(core, directory):
    source = ('unit choices\nfunction present (u :: Unit) -> Maybe Bool is Present true end function\n'
              'function absent (u :: Unit) -> Maybe Bool is Absent end function\nend unit')
    generate(core, directory, 'yaml', source)
    config = yaml.safe_load((directory / 'configuration.yaml').read_text())
    schema = json.loads((directory / 'configuration.schema.json').read_text())
    validator = jsonschema.Draft202012Validator(schema)
    validator.validate(config)
    assert config['choices::absent'] == {'tag': 'Maybe::Absent', 'fields': {}}
    assert config['choices::present'] == {'tag': 'Maybe::Present', 'fields': {'value': True}}
    config['choices::absent']['fields']['value'] = True
    assert list(validator.iter_errors(config)), 'absent and present constructors collapsed'


def antlr_parser(directory):
    jar = Path(os.environ['ANTLR_JAR']).resolve()
    run(['java', '-jar', str(jar), 'LawSpecData.g4'], directory)
    canon_parse(directory, 'antlr4', 'grammarSpec', 'LawSpecData.g4')
    (directory / 'Check.java').write_text('''import org.antlr.v4.runtime.*;
public class Check {
  public static void main(String[] args) throws Exception {
    var lexer = new LawSpecDataLexer(CharStreams.fromString(args[0]));
    var parser = new LawSpecDataParser(new CommonTokenStream(lexer));
    lexer.removeErrorListeners(); parser.removeErrorListeners();
    var errors = new BaseErrorListener() {
      public void syntaxError(Recognizer<?,?> r, Object s, int l, int c, String m, RecognitionException e) {
        throw new IllegalArgumentException(m);
      }
    };
    lexer.addErrorListener(errors); parser.addErrorListener(errors);
    if (args.length > 1) parser.getClass().getMethod(args[1]).invoke(parser);
    else parser.document();
  }
}
''')
    run(['javac', '-cp', str(jar)] + [p.name for p in directory.glob('*.java')], directory)
    args = ['java', '-cp', os.pathsep.join(['.', str(jar)]), 'Check']
    return args


def check_antlr(core, directory):
    generate(core, directory, 'antlr4')
    args = antlr_parser(directory)
    tag = 'configuration::type::Settings::Settings'
    run(args + [f'{tag}(8080,true,["localhost"])'], directory)
    run(args + [f'{tag}(70000,true,[])'], directory)
    schema = json.loads((directory / 'data.schema.json').read_text())
    validator = jsonschema.Draft202012Validator(schema)
    assert list(validator.iter_errors(dict(port=70000, enabled=True, hosts=[]))), 'syntax acceptance became semantic acceptance'
    for wrong in (f'{tag}(8080,true)', f'{tag}(8080,true,["unterminated])',
                  f'{tag}(8080,true,[]) trailing', f'{tag}(8080,"true",[])'):
        run(args + [wrong], directory, ok=False)


def check_antlr_inputs(core, directory):
    fixtures = Path(__file__).resolve().parents[1] / 'test/fixtures'
    generate(core, directory, 'antlr4', (fixtures / 'artifact-antlr-inputs.lawspec').read_text())
    args = antlr_parser(directory)
    manifest = json.loads((directory / 'lawspec-artifacts.json').read_text())
    schema = json.loads((directory / 'data.schema.json').read_text())
    jsonschema.Draft202012Validator.check_schema(schema)
    assert manifest['entryPoints'].keys() == manifest['types'].keys()
    assert manifest['lawsExecuted'] is False

    def entry(scalar):
        matches = [key for key, ty in manifest['types'].items()
                   if ty.startswith('Constructor "inputOnly::type::Box"')
                   and f'Constructor "{scalar}"' in ty]
        assert len(matches) == 1, (scalar, matches)
        key = matches[0]
        result = manifest['entryPoints'][key]
        assert result['schema'] == '#/$defs/' + key
        return result

    tag = 'inputOnly::type::Box::Box'
    small, wide = entry('UInt8'), entry('UInt16')
    for selected in [small, wide]:
        run(args + [f'{tag}(7)', selected['rule']], directory)
        run(args + [f'{tag}(256)', selected['rule']], directory)
        run(args + [f'{tag}(7) trailing', selected['rule']], directory, ok=False)
        run(args + [f'{tag}("bad")', selected['rule']], directory, ok=False)
    small_schema = jsonschema.Draft202012Validator({**schema, '$ref': small['schema']})
    wide_schema = jsonschema.Draft202012Validator({**schema, '$ref': wide['schema']})
    small_schema.validate(dict(payload=7))
    wide_schema.validate(dict(payload=256))
    assert list(small_schema.iter_errors(dict(payload=256))), 'wider generic instance weakened the expected UInt8 input'
    union = jsonschema.Draft202012Validator(schema)
    union.validate(dict(payload=256))
    run(args + [f'[{tag}(true),{tag}(false)]'], directory)
    union.validate([dict(payload=True), dict(payload=False)])
    run(args + [f'[{tag}(7)]'], directory, ok=False)

    rejected = compile_artifact(core, 'antlr4', (fixtures / 'artifact-antlr-indexed-input.lawspec').read_text())
    assert any(diagnostic['code'] == 'target-unsupported' and 'indexed' in diagnostic['message']
               for diagnostic in rejected['diagnostics']), rejected
    assert not rejected.get('files'), 'unsupported indexed input produced partial grammar artifacts'


def check_make(core, directory):
    generate(core, directory, 'make')
    canon_parse(directory, 'make', 'makefile', 'Makefile')
    cli = directory / 'cli'
    cli.write_text('#!/bin/sh\nprintf "%s\\n" "$1" >> calls\n[ "$1" != "$FAIL_STAGE" ]\n')
    cli.chmod(0o755)
    run(['make', '-j4', 'LAWSPEC=./cli'], directory)
    assert (directory / 'calls').read_text().splitlines() == ['check', 'generate', 'test']
    (directory / 'calls').unlink()
    run(['make', '-j4', 'LAWSPEC=./cli'], directory, ok=False,
        env=dict(os.environ, FAIL_STAGE='check'))
    assert (directory / 'calls').read_text().splitlines() == ['check'], 'pipeline continued after failure'


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('targets', nargs='*', metavar='TARGET')
    selected = set(parser.parse_args().targets or ['yaml', 'hcl', 'antlr4', 'make'])
    if selected - {'yaml', 'hcl', 'antlr4', 'make'}:
        parser.error('targets must be yaml, hcl, antlr4 or make')
    core = str(Path(os.environ['LAWSPEC_NATIVE_CORE']).resolve())
    if os.environ.get('CANON_BINARY'):
        repository = Path(os.environ['CANON_REPO']).resolve()
        inventory = Path(__file__).resolve().parents[1] / 'npm/templates.mjs'
        response = run(['node', '--input-type=module', '-e',
                        f'import {{targets}} from {json.dumps(inventory.as_uri())}; console.log(JSON.stringify(targets));'],
                       repository)
        actual = json.loads(response.stdout)
        configured = yaml.safe_load((repository / 'canon.yaml').read_text())['parity']['current']
        assert sorted(actual) == sorted(configured), 'canon current targets differ from the supported LawSpec inventory'
        print(f'Canon: public target inventory matches ({len(actual)} targets)', flush=True)
    with tempfile.TemporaryDirectory(prefix='lawspec-artifact-targets-') as temporary:
        root = Path(temporary)
        if 'yaml' in selected:
            check_yaml(core, root / 'yaml')
            check_empty_type(core, root / 'yaml-empty')
            check_large_integer(core, root / 'yaml-large-integer')
            check_sum(core, root / 'yaml-sum')
            check_restrictions(core, root / 'yaml-restricted', 'yaml')
            print('YAML: checked values and rejection controls passed', flush=True)
        if 'hcl' in selected:
            check_hcl(core, root / 'hcl', EXPECTED)
            check_hcl_type_export(core, root / 'hcl-types')
            check_restrictions(core, root / 'hcl-restricted', 'hcl')
            print('HCL: validation, literal values and rejection controls passed', flush=True)
        if 'antlr4' in selected:
            check_antlr(core, root / 'antlr4')
            check_antlr_inputs(core, root / 'antlr4-inputs')
            print('ANTLR: grammar compilation, typed input/schema selection, indexed rejection and parser controls passed', flush=True)
        if 'make' in selected:
            check_make(core, root / 'make')
            print('Make: ordered execution and failure propagation passed', flush=True)
        if os.environ.get('CANON_BINARY'):
            print(f'Canon: {len(selected)} emitted artifact formats parsed successfully', flush=True)


if __name__ == '__main__':
    main()
