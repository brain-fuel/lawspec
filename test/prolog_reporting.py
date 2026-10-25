"""Execution status must survive PLUnit, pytest and model worker threads.

These are deliberately failing fixture cases. Their observed JUnit records,
rather than process success or human-readable exception text, are the oracle.
ref:DEC-prolog-janus
"""

import json
import os
from pathlib import Path
import subprocess
import sys
from tempfile import TemporaryDirectory
import unittest
import xml.etree.ElementTree as ET


class PrologReporting(unittest.TestCase):
    def run_fixture(
        self,
        source,
        slots,
        selections=(),
        parallel=False,
        conftest="",
        optimized=False,
        select_cases=(),
        list_tests=False,
    ):
        runtime = Path(__file__).resolve().parents[1] / "runtime"
        with TemporaryDirectory(prefix="lawspec-prolog-batch-") as scratch:
            root = Path(scratch)
            (root / "tests").mkdir()
            metadata = [
                {
                    "file": "tests/status.pl",
                    "unit": "status",
                    "hostFile": "tests/status.py",
                    "kind": "test",
                    **slot,
                }
                for slot in slots
            ]
            (root / "lawspec-prolog-tests.json").write_text(json.dumps(metadata))
            (root / "tests/status.pl").write_text(
                "\n".join(
                    [
                        ":- use_module(library(janus)).",
                        ":- use_module(library(plunit)).",
                        ":- begin_tests(status).",
                        *(
                            f":- lawspec_prolog:host_cases('tests/status.pl::{slot['name']}')."
                            for slot in slots
                        ),
                        ":- end_tests(status).",
                    ]
                )
            )
            (root / "tests/status.py").write_text(source)
            if parallel:
                (root / "tests/conftest.py").write_text(
                    "from lawspec_harness import pytest_collection_modifyitems, pytest_pyfunc_call\n"
                    + conftest
                )
            command = [
                sys.executable,
                "-B",
                *(["-O"] if optimized else []),
                "-c",
                "from lawspec_prolog_tests import main; raise SystemExit(main())",
                "--junitxml",
                "results.xml",
            ]
            for name in selections:
                command += ["--select", "tests/status.pl::" + name]
            for name in select_cases:
                command += ["--select-case", name]
            if list_tests:
                command += ["--list-tests"]
            process = subprocess.run(
                command,
                cwd=root,
                capture_output=True,
                text=True,
                timeout=30,
                env=dict(os.environ, PYTHONPATH=str(runtime)),
            )
            report = root / "results.xml"
            return process, ET.parse(report).getroot() if report.exists() else None

    def test_one_native_row_executes_only_its_own_provider_call(self):
        source = """
import pytest
@pytest.mark.parametrize('amount', [10,20,30], ids=['first','middle','last'])
def test_pay__boundary(amount):
    print('PROVIDER_EXECUTED=' + str(amount))
    assert amount != MUTATED
"""
        slots = [{"name": "test_pay", "selection": "test_pay__"}]
        for mutated, status in [(99, 0), (20, 1)]:
            process, suite = self.run_fixture(
                source.replace("MUTATED", str(mutated)),
                slots,
                select_cases=["tests/status.py::test_pay__boundary[middle]"],
            )
            self.assertEqual(
                process.returncode, status, process.stdout + process.stderr
            )
            self.assertEqual(process.stdout.count("PROVIDER_EXECUTED="), 1)
            self.assertIn("PROVIDER_EXECUTED=20", process.stdout)
            self.assertEqual(suite.get("tests"), "1")
            case = suite.find("testcase")
            self.assertEqual(case.get("name"), "test_pay__boundary[middle]")
            self.assertEqual(case.find("failure") is not None, status == 1)
            self.assertIn("1/1", process.stderr)

    def test_native_listing_collects_stable_rows_without_provider_execution(self):
        process, suite = self.run_fixture(
            """
import pytest
@pytest.mark.parametrize('value', [1,2], ids=['left','right'])
def test_pay__boundary(value):
    print('PROVIDER_EXECUTED')
    assert False
""",
            [{"name": "test_pay", "selection": "test_pay__"}],
            list_tests=True,
        )
        self.assertEqual(process.returncode, 0, process.stdout + process.stderr)
        self.assertIsNone(suite)
        self.assertNotIn("PROVIDER_EXECUTED", process.stdout)
        listed = json.loads(process.stdout)
        self.assertEqual(
            [row["name"] for row in listed],
            [
                "tests/status.py::test_pay__boundary[left]",
                "tests/status.py::test_pay__boundary[right]",
            ],
        )
        self.assertEqual({row["unit"] for row in listed}, {"status"})

    def test_unknown_and_repeated_native_selections_cannot_pass(self):
        source = "def test_pay__boundary(): print('PROVIDER_EXECUTED')"
        slots = [{"name": "test_pay", "selection": "test_pay__"}]
        process, suite = self.run_fixture(
            source, slots, select_cases=["tests/status.py::missing"]
        )
        self.assertEqual(process.returncode, 1, process.stdout + process.stderr)
        self.assertNotIn("PROVIDER_EXECUTED", process.stdout)
        self.assertGreater(int(suite.get("errors")), 0)
        process, suite = self.run_fixture(
            source, slots, select_cases=["tests/status.py::test_pay__boundary"] * 2
        )
        self.assertEqual(process.returncode, 2, process.stdout + process.stderr)
        self.assertIsNone(suite)

    def test_optimized_python_cannot_turn_disabled_assertions_into_success(self):
        tested, report = self.run_fixture(
            "def test_false():\n    assert False\n",
            [{"name": "test_false", "exact": True}],
            optimized=True,
        )
        self.assertEqual(tested.returncode, 2, tested.stdout + tested.stderr)
        self.assertIsNone(report)
        self.assertIn("require enabled Python assertions", tested.stderr)

    def test_parallel_cases_keep_incomplete_and_failure_scopes(self):
        slots = [
            {"name": name, "exact": True}
            for name in ["test_clean", "test_failure", "test_unknown"]
        ]
        tested, suite = self.run_fixture(
            """
from threading import Barrier
from lawspec_prolog import Incomplete
_LAWSPEC_PARALLEL = True
gate = Barrier(3, timeout=5)

def test_clean():
    gate.wait()
    assert True

def test_failure():
    gate.wait()
    assert False, "incomplete is just a word in this assertion"

def test_unknown():
    gate.wait()
    try:
        raise Incomplete("native computation declined in its parallel worker")
    except Incomplete:
        pass
""",
            slots,
            parallel=True,
        )
        self.assertEqual(tested.returncode, 1, tested.stdout + tested.stderr)
        cases = {case.get("name"): case for case in suite.findall("testcase")}
        self.assertEqual(set(cases), {slot["name"] for slot in slots})
        self.assertIsNone(cases["test_clean"].find("error"))
        self.assertIsNone(cases["test_clean"].find("failure"))
        self.assertIsNotNone(cases["test_failure"].find("failure"))
        self.assertIsNone(cases["test_failure"].find("error"))
        self.assertIsNotNone(cases["test_unknown"].find("error"))
        self.assertEqual(suite.get("errors"), "1")

    def test_partial_selection_keeps_exact_models_and_omits_benchmarks(self):
        slots = [
            {"name": "test_left", "selection": "test_left__"},
            {"name": "test_leftover", "selection": "test_leftover__"},
            {"name": "test_model", "exact": True},
            {"name": "test_benchmark", "exact": True, "kind": "benchmark"},
        ]
        tested, suite = self.run_fixture(
            """
def test_left__boundary(): pass
def test_left__example(): pass
def test_leftover__boundary(): assert False, "unselected law"
def test_model(): pass
def test_benchmark(): assert False, "unselected benchmark"
def test_unlisted(): assert False, "unlisted test"
""",
            slots,
            selections=["test_left", "test_model"],
        )
        self.assertEqual(tested.returncode, 0, tested.stdout + tested.stderr)
        self.assertEqual(
            {case.get("name") for case in suite.findall("testcase")},
            {"test_left__boundary", "test_left__example", "test_model"},
        )

    def test_unscoped_worker_unknown_invalidates_active_parallel_cases(self):
        slots = [
            {"name": name, "exact": True}
            for name in ["test_fast", "test_wait", "test_unknown_worker"]
        ]
        tested, suite = self.run_fixture(
            """
from threading import Barrier, Event, Thread
from lawspec_prolog import Incomplete
_LAWSPEC_PARALLEL = True
ready = Barrier(2, timeout=5)
reported_fast = Event()
done = Event()

def test_fast(): pass

def test_wait():
    ready.wait()
    assert done.wait(5)

def test_unknown_worker():
    ready.wait()
    assert reported_fast.wait(5)
    def worker():
        try:
            raise Incomplete("a plain model thread has no inherited test context")
        except Incomplete:
            pass
    thread = Thread(target=worker)
    thread.start()
    thread.join()
    done.set()
""",
            slots,
            parallel=True,
            conftest="""
import pytest
@pytest.hookimpl(hookwrapper=True)
def pytest_runtest_protocol(item):
    yield
    if item.name == 'test_fast':
        item.module.reported_fast.set()
""",
        )
        self.assertEqual(tested.returncode, 1, tested.stdout + tested.stderr)
        cases = {case.get("name"): case for case in suite.findall("testcase")}
        self.assertIsNone(cases["test_fast"].find("error"))
        self.assertIsNotNone(cases["test_wait"].find("error"))
        self.assertIsNotNone(cases["test_unknown_worker"].find("error"))
        self.assertEqual(suite.get("errors"), "2")

    def test_missing_native_cases_cannot_pass_a_batch(self):
        tested, suite = self.run_fixture(
            "def helper(): pass\n", [{"name": "test_missing", "exact": True}]
        )
        self.assertEqual(tested.returncode, 1, tested.stdout + tested.stderr)
        self.assertEqual(suite.get("errors"), "1")
        self.assertIsNotNone(suite.find("testcase/error"))

    def test_equal_unittest_method_names_retain_distinct_native_identities(self):
        tested, suite = self.run_fixture(
            """
import unittest
class First(unittest.TestCase):
    def test_value(self): self.assertEqual(1+1, 2)
class Second(unittest.TestCase):
    def test_value(self): self.assertEqual(2+2, 4)
""",
            [{"name": "support", "selection": "", "kind": "support"}],
        )
        self.assertEqual(tested.returncode, 0, tested.stdout + tested.stderr)
        cases = suite.findall("testcase")
        self.assertEqual(len(cases), 2)
        self.assertEqual({case.get("name") for case in cases}, {"test_value"})
        self.assertEqual(len({case.get("classname") for case in cases}), 2)

    def test_a_broken_host_report_never_reexecutes_the_batch(self):
        tested, suite = self.run_fixture(
            """
from pathlib import Path
def test_first():
    path = Path('runs')
    path.write_text(path.read_text()+'first\\n' if path.exists() else 'first\\n')
def test_second():
    path = Path('runs')
    path.write_text(path.read_text()+'second\\n')
""",
            [
                {"name": "test_first", "exact": True},
                {"name": "test_second", "exact": True},
            ],
            parallel=True,
            conftest="""
import pytest
@pytest.hookimpl(trylast=True)
def pytest_sessionfinish(session):
    from pathlib import Path
    print('NATIVE_RUNS=' + str(len(Path('runs').read_text().splitlines())))
    Path(session.config.option.xmlpath).write_text('not XML')
""",
        )
        self.assertEqual(tested.returncode, 1, tested.stdout + tested.stderr)
        self.assertEqual(suite.get("errors"), "2")
        self.assertTrue(
            all(
                "host execution report unavailable" in case.find("error").text
                for case in suite.findall("testcase")
            )
        )
        self.assertEqual(tested.stdout.count("NATIVE_RUNS=2"), 1)

    def test_late_worker_event_retains_its_original_case(self):
        tested, suite = self.run_fixture(
            """
from contextvars import copy_context
from threading import Event, Thread
from lawspec_prolog import Incomplete
go = Event()
thread = None

def test_origin():
    global thread
    def worker():
        assert go.wait(5)
        try:
            raise Incomplete("the originating case has already produced its pytest report")
        except Incomplete:
            pass
    context = copy_context()
    thread = Thread(target=context.run, args=(worker,))
    thread.start()

def test_later():
    go.set()
    thread.join()
""",
            [
                {"name": "test_origin", "exact": True},
                {"name": "test_later", "exact": True},
            ],
        )
        self.assertEqual(tested.returncode, 1, tested.stdout + tested.stderr)
        cases = {case.get("name"): case for case in suite.findall("testcase")}
        self.assertIsNotNone(cases["test_origin"].find("error"))
        self.assertIsNone(cases["test_later"].find("error"))
        self.assertIsNone(cases["test_later"].find("failure"))

    def test_ambiguous_native_slots_cannot_pass_a_batch(self):
        tested, suite = self.run_fixture(
            "def test_law__case(): pass\n",
            [
                {"name": "test_law", "selection": "test_law__"},
                {"name": "test_law__case", "exact": True},
            ],
        )
        self.assertEqual(tested.returncode, 1, tested.stdout + tested.stderr)
        self.assertEqual(suite.get("errors"), "2")

    def test_a_failed_slot_stops_its_remaining_cases_without_hiding_siblings(self):
        tested, suite = self.run_fixture(
            """
def test_bad__first(): assert False, "an observed native mismatch"
def test_bad__second(): assert False, "this case is skipped after the first mismatch"
def test_good__case(): pass
""",
            [
                {"name": "test_bad", "selection": "test_bad__"},
                {"name": "test_good", "selection": "test_good__"},
            ],
        )
        self.assertEqual(tested.returncode, 1, tested.stdout + tested.stderr)
        cases = {case.get("name"): case for case in suite.findall("testcase")}
        self.assertIsNotNone(cases["test_bad__first"].find("failure"))
        self.assertIsNotNone(cases["test_bad__second"].find("skipped"))
        self.assertIsNone(cases["test_good__case"].find("failure"))
        self.assertIsNone(cases["test_good__case"].find("error"))
        self.assertIsNone(cases["test_good__case"].find("skipped"))

    def test_structured_incomplete_is_distinct_from_failure_and_pass(self):
        runtime = Path(__file__).resolve().parents[1] / "runtime"
        with TemporaryDirectory(prefix="lawspec-prolog-status-") as scratch:
            root = Path(scratch)
            (root / "tests").mkdir()
            names = [
                "test_pass",
                "test_failure",
                "test_unknown_worker",
                "test_hidden_unknown",
            ]
            (root / "lawspec-prolog-tests.json").write_text(
                json.dumps(
                    [
                        {
                            "file": "tests/status.pl",
                            "name": name,
                            "unit": "status",
                            "hostFile": "tests/status.py",
                            "exact": True,
                            "kind": "test",
                        }
                        for name in names
                    ]
                )
            )
            (root / "tests/status.pl").write_text(
                "\n".join(
                    [
                        ":- use_module(library(janus)).",
                        ":- use_module(library(plunit)).",
                        ":- begin_tests(status).",
                        *(
                            f"test({name}) :- py_call(lawspec_prolog_tests:run_case('tests/status.pl::{name}'), @(true))."
                            for name in names
                        ),
                        ":- end_tests(status).",
                    ]
                )
            )
            (root / "tests/status.py").write_text("""
from threading import Thread
from lawspec_prolog import Incomplete

def test_pass():
    assert True

def test_failure():
    assert False, "the word incomplete does not change a failed assertion"

def test_unknown_worker():
    def worker():
        try:
            raise Incomplete("bounded native search")
        except Incomplete:
            pass  # A model can retain a description after testing a history.
    thread = Thread(target=worker)
    thread.start()
    thread.join()
    assert False, "the model could not complete its history"

def test_hidden_unknown():
    try:
        raise Incomplete("the native computation declined")
    except Incomplete:
        pass
""")
            tested = subprocess.run(
                [
                    sys.executable,
                    "-B",
                    "-c",
                    "from lawspec_prolog_tests import main; raise SystemExit(main())",
                    "--junitxml",
                    "results.xml",
                ],
                cwd=root,
                capture_output=True,
                text=True,
                env=dict(os.environ, PYTHONPATH=str(runtime)),
            )
            self.assertEqual(tested.returncode, 1, tested.stdout + tested.stderr)
            suite = ET.parse(root / "results.xml").getroot()
            cases = suite.findall("testcase")
            self.assertEqual(len(cases), 4, tested.stdout + tested.stderr)
            unknown = [
                case.get("name")
                for case in cases
                if case.find(
                    "properties/property[@name='lawspec.status'][@value='incomplete']"
                )
                is not None
            ]
            self.assertEqual(unknown, ["test_unknown_worker", "test_hidden_unknown"])
            failures = [
                case.get("name") for case in cases if case.find("failure") is not None
            ]
            self.assertEqual(failures, ["test_failure"])
            self.assertEqual(
                [case.get("name") for case in cases if case.find("error") is not None],
                ["test_unknown_worker", "test_hidden_unknown"],
            )
            self.assertEqual(suite.get("errors"), "2")


if __name__ == "__main__":
    unittest.main(verbosity=2)
