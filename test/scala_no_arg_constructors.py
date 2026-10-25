"""Native Scala constructor binding conformance, including raw generic classes.

The application constructor is checked by Scala without a generated Java
reference to the Scala application class. ref:DEC-native-bindings-typed-identity
"""

from pathlib import Path
import json
import os
import shutil
import subprocess
import tempfile
import xml.etree.ElementTree as ET

root = Path(__file__).resolve().parent.parent
request = {
    "schemaVersion": 5,
    "languageProfile": "1.0-rc.2",
    "method": "planGeneration",
    "target": "scala",
    "sources": [
        {
            "path": "constructors.lawspec",
            "content": "unit sample.constructors\nhandle Box\nnewBox :: Unit -> Unit -> Box\nend unit\n",
        }
    ],
    "nativeBindings": {
        "types": [
            {
                "type": "sample.constructors::type::Box",
                "native": ["application", "Factory", "Box"],
            }
        ],
        "functions": [
            {
                "declaration": "sample.constructors::newBox",
                "constructor": ["application", "Factory", "Box"],
            }
        ],
    },
}
compiler = os.environ.get("LAWSPEC_CORE_EXECUTABLE")
command = [compiler] if compiler else ["stack", "exec", "lawspec-core", "--"]
response = json.loads(
    subprocess.check_output(command, input=json.dumps(request), text=True, cwd=root)
)
assert not response["diagnostics"], response["diagnostics"]
with tempfile.TemporaryDirectory(prefix="lawspec-scala-constructors-") as directory:
    project = Path(directory) / "scala"
    project.mkdir()
    shutil.copyfile(
        root / ".integration/scala/project.scala", project / "project.scala"
    )
    for artifact in response["files"]:
        target = project / artifact["path"]
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(artifact["content"])
        if target.suffix == ".java":
            assert "application.Factory.Box" not in artifact["content"], artifact[
                "path"
            ]
    application = project / "src/main/scala/application/Factory.scala"
    application.parent.mkdir(parents=True, exist_ok=True)
    application.write_text("""package application
object Factory {
  var constructions = 0
  final class Box[A <: java.lang.Number] {
    constructions += 1
  }
}
""")
    tests = project / "src/test/scala/ConstructorBindingTest.scala"
    tests.parent.mkdir(parents=True, exist_ok=True)
    tests.write_text("""import org.scalatest.funsuite.AnyFunSuite
class ConstructorBindingTest extends AnyFunSuite {
  test("zero-argument bounded generic constructors make fresh native objects") {
    val first = sample.Constructors.newBox((), ())
    val second = sample.Constructors.newBox((), ())
    assert(first.isInstanceOf[application.Factory.Box[?]])
    assert(second.isInstanceOf[application.Factory.Box[?]])
    assert(!(first.asInstanceOf[AnyRef] eq second.asInstanceOf[AnyRef]))
    assert(application.Factory.constructions == 2)
  }
}
""")
    reports = project / ".lawspec/junit"
    subprocess.run(
        ["scala", "test", ".", "--power", "--offline", "--", "-u", str(reports)],
        cwd=project,
        check=True,
    )
    cases = [
        case
        for file in reports.glob("*.xml")
        for case in ET.parse(file).getroot().iter("testcase")
    ]
    assert (
        len(cases) == 1
        and cases[0].find("failure") is None
        and cases[0].find("error") is None
    )
print("Scala zero-argument generic constructor conformance passed")
