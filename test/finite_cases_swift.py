"""Compile maintained Swift runtimes and run independent finite-cover observations.

ref:DEC-planned-generation ref:DEC-tests-cite-requirements
"""

from pathlib import Path
import shutil
import os
import json
import uuid
import subprocess
import tempfile

root = Path(__file__).resolve().parent.parent
with tempfile.TemporaryDirectory(prefix="lawspec-finite-swift-") as directory:
    project = Path(directory)
    sources = project / "Sources"
    shutil.copytree(root / "runtime/swift/LawSpecRuntime", sources / "LawSpecRuntime")
    testing = sources / "LawSpecTesting"
    testing.mkdir()
    shutil.copyfile(
        root / "runtime/swift/LawSpecTesting/FiniteCases.swift",
        testing / "FiniteCases.swift",
    )
    main = sources / "Conformance"
    main.mkdir()
    shutil.copyfile(root / "test/finite_cases.swift", main / "main.swift")
    tests = project / "Tests" / "ConformanceTests"
    tests.mkdir(parents=True)
    shutil.copyfile(root / "test/finite_cases_testing.swift", tests / "Selection.swift")
    (project / "Package.swift").write_text(
        "// swift-tools-version: 6.3\n"
        "import PackageDescription\n"
        'let package = Package(name: "FiniteConformance", platforms: [.macOS(.v26)], targets: [\n'
        '  .target(name: "LawSpecRuntime"),\n'
        '  .target(name: "LawSpecTesting", dependencies: ["LawSpecRuntime"]),\n'
        '  .executableTarget(name: "Conformance", dependencies: ["LawSpecRuntime", "LawSpecTesting"]),\n'
        '  .testTarget(name: "ConformanceTests", dependencies: ["LawSpecRuntime", "LawSpecTesting"])\n'
        "])\n",
        encoding="utf-8",
    )
    subprocess.run(
        ["swift", "run", "--package-path", str(project), "Conformance"], check=True
    )
    artifacts = root / ".artifacts" / "finite-swift"
    artifacts.mkdir(parents=True, exist_ok=True)
    for label, selected, expected, failing in [
        ("all", None, 5, False),
        ("selected", [{"unit": "conformance", "name": "rows"}], 3, False),
        ("failed", [{"unit": "conformance", "name": "rows"}], 3, True),
        ("unknown", [{"unit": "conformance", "name": "missing"}], 0, True),
    ]:
        token = str(uuid.uuid4())
        report = artifacts / f"{label}.xml"
        events = artifacts / f"{label}-events.jsonl"
        events.unlink(missing_ok=True)
        environment = {
            **os.environ,
            "LAWSPEC_SWIFT_RUN": token,
            "LAWSPEC_SWIFT_REPORT": str(events),
            "LAWSPEC_SWIFT_LAWS": json.dumps(selected) if selected else "",
            "FINITE_CASE_FAIL": "1" if label == "failed" else "",
        }
        result = subprocess.run(
            [
                "swift",
                "test",
                "--package-path",
                str(project),
                "--filter",
                "ordered",
                "--xunit-output",
                str(report),
            ],
            env=environment,
            check=False,
        )
        assert (result.returncode != 0) == failing, (label, result.returncode)
        if label == "unknown":
            assert not events.exists(), "unknown law must fail before publishing a plan"
            continue
        rows = [json.loads(line) for line in events.read_text().splitlines()]
        assert all(row["version"] == 1 and row["run"] == token for row in rows)
        plans = [row for row in rows if row["event"] == "plan"]
        assert plans and all(len(row["cases"]) == expected for row in plans)
        assert sum(row["event"] == "case-start" for row in rows) == expected
        ends = [row for row in rows if row["event"] == "case-end"]
        assert len(ends) == expected
        failures = [row for row in ends if row["status"] == "failed"]
        assert len(failures) == (1 if failing else 0)
        if failing:
            assert failures[0]["id"] == "rows#1"
            assert "IndependentBoundaryMutation" in failures[0]["failure"]
        (artifacts / f"{label}-run.json").write_text(
            json.dumps(
                {
                    "run": token,
                    "file": str(events),
                    "junit": str(report.with_name(report.stem + "-swift-testing.xml")),
                },
                indent=2,
            )
            + "\n"
        )
