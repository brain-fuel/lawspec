"""Compile and check maintained Go runtimes without rewriting their source.

ref:DEC-planned-generation
"""

from pathlib import Path
import os
import shutil
import subprocess
import tempfile


root = Path(__file__).resolve().parent.parent
with tempfile.TemporaryDirectory(prefix="lawspec-finite-go-") as directory:
    for name in ["lawspec_runtime.go", "lawspec_schema.go"]:
        shutil.copyfile(root / "runtime" / name, Path(directory) / name)
    shutil.copyfile(root / "test/finite_cases_test.go", Path(directory) / "finite_cases_test.go")
    subprocess.run(
        ["go", "test", "-count=1", "-v", "."],
        cwd=directory,
        env={**os.environ, "GO111MODULE": "off", "GOTOOLCHAIN": "local"},
        check=True,
    )
print("Go finite-cover conformance passed")
