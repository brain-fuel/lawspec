"""PLUnit law slots backed by the existing generated Hypothesis/pytest cases.

Selected host cases run once in one pytest session, retaining refinements,
shrinking, examples, replay, scheduling and shared-resource scopes. Each PLUnit
test consumes its actual recorded outcome. Collected node identities must match
the JUnit observations; empty discovery and collection errors cannot pass.
ref:DEC-prolog-janus
"""
import argparse
from copy import deepcopy
from contextvars import ContextVar
from functools import wraps
from pathlib import Path
import json
import logging
import sys
from tempfile import TemporaryDirectory
import xml.etree.ElementTree as ET

import janus_swi as janus
import pytest
import lawspec_prolog  # noqa: F401 - consult the sibling Prolog runtime


_cases = {}
_observed = {}
_selected = []
_results = None
_called = set()
_current_case = ContextVar('lawspec_prolog_case', default=None)


class _ExecutionStatus(logging.Handler):
    """Retain explicit unknown results through ordinary pytest/JUnit reports.

    Python logging carries structured events from model worker threads too.
    Each selected function carries a context through the host's parallel
    scheduler and asyncio workers. A plain child thread may not inherit that
    context: in that case all currently active cases remain incomplete.
    """
    def __init__(self, selected):
        super().__init__()
        self.current = None
        self.incomplete = set()
        self.active = set()
        self.selected = selected
        self.collected = {key: {} for key in selected}
        self.node_slots = {}
        self.failed_slots = set()

    def emit(self, record):
        if getattr(record, 'lawspec_status', None) == 'incomplete':
            node = _current_case.get()
            if node not in self.node_slots:
                node = None
            self.incomplete.update({node} if node is not None else
                                   self.active or {self.current})

    @pytest.hookimpl(tryfirst=True)
    def pytest_collection_modifyitems(self, session, config, items):
        kept, removed = [], []
        for item in items:
            matches = [key for key, case in self.selected.items()
                       if Path(case['hostFile']).resolve() == item.path.resolve()
                       and (item.name == case['name'] if case.get('exact') else
                            item.name.startswith(case['selection']))]
            if not matches:
                removed.append(item)
                continue
            if len(matches) != 1:
                raise pytest.UsageError('native case belongs to multiple Prolog slots: ' + item.nodeid)
            key = matches[0]
            if item.nodeid in self.collected[key]:
                raise pytest.UsageError('duplicate native case in a Prolog slot: ' + item.nodeid)
            self.collected[key][item.nodeid] = item.name
            self.node_slots[item.nodeid] = key
            item.user_properties.append(('lawspec.slot', key))
            item.user_properties.append(('lawspec.nodeid', item.nodeid))
            # The existing harness submits item.obj to its worker pool. Retain
            # Hypothesis's public wrapper attributes and normal fixture signature.
            item.obj = self.traced(item.nodeid, item.obj)
            kept.append(item)
        items[:] = kept
        config.hook.pytest_deselected(items=removed)

    def pytest_runtest_setup(self, item):
        # Retain the former per-slot fail-fast behavior without stopping the
        # other selected laws. Parallel items may already be running in the
        # established host pool, so their ordinary reports must be retained.
        if (self.node_slots[item.nodeid] in self.failed_slots and
                not getattr(item.module, '_LAWSPEC_PARALLEL', False)):
            pytest.skip('an earlier native case in this PLUnit slot did not complete successfully')

    def traced(self, node, function):
        @wraps(function)
        def run(*args, **kwargs):
            token = _current_case.set(node)
            with self.lock:
                self.active.add(node)
            try:
                return function(*args, **kwargs)
            finally:
                with self.lock:
                    self.active.discard(node)
                _current_case.reset(token)
        return run

    @pytest.hookimpl(hookwrapper=True)
    def pytest_runtest_protocol(self, item):
        self.current = item.nodeid
        try:
            yield
        finally:
            self.current = None

    @pytest.hookimpl(hookwrapper=True)
    def pytest_runtest_makereport(self, item):
        result = yield
        report = result.get_result()
        if item.nodeid in self.incomplete:
            report.user_properties.append(('lawspec.status', 'incomplete'))
        if report.failed or item.nodeid in self.incomplete or None in self.incomplete:
            self.failed_slots.add(self.node_slots[item.nodeid])


def _mark_incomplete(element):
    properties = element.find('properties')
    if properties is None:
        properties = ET.SubElement(element, 'properties')
    if properties.find("property[@name='lawspec.status'][@value='incomplete']") is None:
        ET.SubElement(properties, 'property', name='lawspec.status', value='incomplete')
    # Standard JUnit consumers must also see an execution error. The property
    # carries the more precise status for LawSpec without reporting a false pass.
    if element.find('error') is None:
        failure = element.find('failure')
        if failure is not None:
            failure.tag = 'error'
            failure.set('type', 'lawspec.Incomplete')
        else:
            ET.SubElement(element, 'error', type='lawspec.Incomplete',
                          message='native execution did not produce a complete result')


def _incomplete(key, case, message):
    element = ET.Element('testcase', name=case['name'], classname=case['file'])
    ET.SubElement(element, 'error').text = message
    _mark_incomplete(element)
    _observed['bridge::' + key] = element
    return False


def _run_selected():
    """One host session retains the existing unit scheduler and resource scope.

    PLUnit reads cached outcomes only after actual selected host cases ran.
    A failing sibling cannot invent, duplicate or suppress another slot's cases.
    """
    selected = {key: _cases[key] for key in _selected}
    results = dict.fromkeys(selected, False)
    by_slot = {key: [] for key in selected}
    with TemporaryDirectory(prefix='lawspec-prolog-report-') as scratch:
        report = Path(scratch) / 'pytest.xml'
        files = list(dict.fromkeys(case['hostFile'] for case in selected.values()))
        status = _ExecutionStatus(selected)
        logger = logging.getLogger('lawspec.prolog.incomplete')
        level = logger.level
        logger.setLevel(logging.INFO)
        logger.addHandler(status)
        try:
            # Generated checks already carry law/argument/expected-value
            # diagnostics. Plain assertions and standard Python tracebacks
            # avoid pytest's whole-module AST work while retaining call frames
            # and failure messages in JUnit.
            code = pytest.main(['-q', '-s', '--assert=plain', '--tb=native', *files,
                                '--junitxml=' + str(report)], plugins=[status])
        finally:
            logger.removeHandler(status)
            logger.setLevel(level)
        if not report.exists():
            for key, case in selected.items():
                _incomplete(key, case, 'pytest produced no execution report')
            return results
        observed = ET.parse(report).getroot().findall('.//testcase')
        invalid = None
        seen_nodes = set()
        for element in observed:
            slot = element.find("properties/property[@name='lawspec.slot']")
            key = slot.get('value') if slot is not None else None
            identity = element.find("properties/property[@name='lawspec.nodeid']")
            node = identity.get('value') if identity is not None else None
            if (key not in selected or node not in status.collected[key] or
                    element.get('name') != status.collected[key][node]):
                invalid = 'execution report contains a native case outside the selected slots'
                continue
            if node in seen_nodes:
                invalid = 'execution report repeats a collected native case'
                continue
            seen_nodes.add(node)
            if node in status.incomplete or None in status.incomplete or element.find(
                    "properties/property[@name='lawspec.status'][@value='incomplete']") is not None:
                _mark_incomplete(element)
            native = (element.get('classname'), element.get('name'))
            if native in _observed:
                invalid = 'duplicate native case across Prolog slots'
                continue
            _observed[native] = deepcopy(element)
            by_slot[key].append(element)
    if code not in (pytest.ExitCode.OK, pytest.ExitCode.TESTS_FAILED):
        invalid = f'pytest execution incomplete: {code.name}'
    for key, case in selected.items():
        cases = by_slot[key]
        if invalid is not None:
            _incomplete(key, case, invalid)
        elif not cases or {element.find("properties/property[@name='lawspec.nodeid']").get('value')
                           for element in cases} != set(status.collected[key]):
            _incomplete(key, case, 'the selected PLUnit slot did not observe all its collected host cases')
        else:
            results[key] = all(element.find('failure') is None and element.find('error') is None
                               for element in cases)
    return results


def run_case(key):
    """A PLUnit callback consumes one actual host outcome, once per slot."""
    global _results
    if key not in _selected:
        raise ValueError('PLUnit called an unselected native slot: ' + key)
    if key in _called:
        return _incomplete(key, _cases[key], 'PLUnit called a native slot more than once')
    _called.add(key)
    if _results is None:
        # An infrastructure error must not cause a later PLUnit callback to
        # execute the selected native cases a second time.
        _results = dict.fromkeys(_selected, False)
        try:
            _results = _run_selected()
        except Exception as error:
            for selected in _selected:
                _incomplete(selected, _cases[selected],
                            f'host execution report unavailable: {type(error).__name__}: {error}')
    return _results[key]


def _report(path):
    values = list(_observed.values())
    suite = ET.Element('testsuite', name='lawspec-prolog',
                       tests=str(len(values)),
                       failures=str(sum(v.find('failure') is not None for v in values)),
                       errors=str(sum(v.find('error') is not None for v in values)),
                       skipped=str(sum(v.find('skipped') is not None for v in values)))
    suite.extend(values)
    output = Path(path)
    output.parent.mkdir(parents=True, exist_ok=True)
    ET.ElementTree(suite).write(output, encoding='utf-8', xml_declaration=True)


def main(argv=None):
    global _results
    sys.modules.setdefault('lawspec_prolog_tests', sys.modules[__name__])
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--select', action='append', default=[], metavar='FILE::NAME')
    parser.add_argument('--junitxml')
    options = parser.parse_args(argv)
    if not __debug__:
        parser.error('Prolog host tests require enabled Python assertions; remove -O/PYTHONOPTIMIZE')
    root = Path.cwd()
    metadata = json.loads((root / 'lawspec-prolog-tests.json').read_text())
    _cases.clear()
    _observed.clear()
    _called.clear()
    _results = None
    for case in metadata:
        key = case['file'] + '::' + case['name']
        if key in _cases:
            raise ValueError('duplicate Prolog native test slot: ' + key)
        _cases[key] = case
    selected = options.select or [key for key, case in _cases.items()
                                 if case.get('kind') != 'benchmark']
    if not selected:
        parser.error('no executable Prolog law slots were generated')
    if len(selected) != len(set(selected)):
        parser.error('a Prolog native test slot was selected more than once')
    unknown = set(selected) - set(_cases)
    if unknown:
        parser.error('unknown Prolog test slot: ' + ', '.join(sorted(unknown)))
    selected = list(dict.fromkeys([key for key, case in _cases.items()
                                  if case.get('kind') == 'support'] + selected))
    _selected[:] = selected
    for file in dict.fromkeys(_cases[key]['file'] for key in selected):
        janus.consult(str(root / file))
    selectors = [(_cases[key]['unit'], _cases[key]['name']) for key in selected]
    # Tuples become SWI's -(Unit,Name); the runtime makes qualified selectors.
    # Names stay data rather than being interpolated into executable source.
    truth = janus.cmd('lawspec_prolog', 'run_slots', selectors)
    if options.junitxml:
        _report(options.junitxml)
    return 0 if truth is True else 1


if __name__ == '__main__':
    raise SystemExit(main())
