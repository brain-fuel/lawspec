"""Black-box JVM cover conformance, shared by every target using the Java runtime.

ref:DEC-planned-generation
"""

from pathlib import Path
import os
import subprocess
import tempfile


root = Path(__file__).resolve().parent.parent
classpath = subprocess.check_output(
    ["coursier", "fetch", "--classpath", "org.bouncycastle:bcprov-jdk18on:1.86"],
    text=True,
).strip()
with tempfile.TemporaryDirectory(prefix="lawspec-finite-jvm-") as directory:
    subprocess.run(
        [
            "javac",
            "-cp",
            classpath,
            "-d",
            directory,
            str(root / "runtime/LawSpecRuntime.java"),
            str(root / "runtime/LawSpecNetwork.java"),
            str(root / "test/FiniteCases.java"),
        ],
        check=True,
    )
    subprocess.run(
        ["java", "-Xmx128m", "-cp", directory + os.pathsep + classpath, "FiniteCases"],
        check=True,
    )
