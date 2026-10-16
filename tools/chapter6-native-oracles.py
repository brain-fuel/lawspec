"""Compare native assembly and emitted checked codecs with independent vectors."""

import argparse
import hashlib
import importlib.util
import json
from pathlib import Path
import sys


def load_candidate(path):
    spec = importlib.util.spec_from_file_location("chapter6_candidate", path)
    candidate = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(candidate)
    return candidate.assemble


def equal(actual, expected, suite, source):
    if actual != expected:
        raise AssertionError(
            f"ORACLE_{suite}: {source!r}: expected {expected!r}, actual {actual!r}"
        )


def variants(data, base, text, symbols):
    values = {}
    for candidate in vars(data).values():
        if isinstance(candidate, type) and candidate is not base and issubclass(candidate, base):
            value = candidate()
            spelling = text(symbols, value)
            if spelling in values:
                raise AssertionError(f"ORACLE_C: duplicate authored spelling {spelling!r}")
            values[spelling] = value
    return values


def check(candidate, fixture, generated, suites):
    sys.path.insert(0, str(generated / "src"))
    import lawspec_data as data
    from lawspec_definitions.nand2tetris import chap06 as checked

    assemble = load_candidate(candidate)
    provenance = json.loads((fixture / "provenance.json").read_text())
    vector_bytes = (fixture / "c-instructions.tsv").read_bytes()
    equal(hashlib.sha256(vector_bytes).hexdigest(), provenance["cInstructions"]["sha256"], "C", "fixture digest")
    rows = [line.split("\t") for line in vector_bytes.decode().splitlines()]
    equal(len(rows), 1792, "C", "fixture size")
    equal(len({source for source, _ in rows}), 1792, "C", "distinct instructions")
    symbols = {}
    counts = {}

    if "a" in suites:
        digest = hashlib.sha256()
        for address in range(32768):
            source = f"@{address}"
            expected = f"{address:016b}"
            digest.update(f"{source}\t{expected}\n".encode())
            equal(assemble(source), [expected], "A", source)
            equal(checked.binary16(symbols, address), expected, "A", "checked binary16 " + source)
        equal(digest.hexdigest(), provenance["aInstructions"]["sha256"], "A", "upstream corpus digest")
        counts["aInstructions"] = 32768

    if "c" in suites:
        computations = variants(data, data.Comp, checked.compText, symbols)
        destinations = variants(data, data.Dest, checked.destText, symbols)
        jumps = variants(data, data.Jump, checked.jumpText, symbols)
        equal((len(computations), len(destinations), len(jumps)), (28, 8, 8), "C", "authored domains")
        for source, expected in rows:
            instruction, _, jump = source.partition(";")
            dest, separator, computation = instruction.partition("=")
            if not separator:
                dest, computation = "", dest
            equal(assemble(source), [expected], "C", source)
            actual = checked.computeWord(symbols, computations[computation], destinations[dest], jumps[jump])
            equal(actual, expected, "C", "checked computeWord " + source)
        counts["cInstructions"] = 1792

    if "state" in suites:
        programs = [
            ("", []),
            (" \t\r\n// ignored @phantom (FAKE) D=M\r\n(EMPTY)\n", []),
            ("@first\n@second\n@first\n", [16, 17, 16]),
            ("@second\n@first\n@second\n", [16, 17, 16]),
            ("@first\n@second\n@first\n", [16, 17, 16]),
            ("@finish\nD=0\n(finish)\n@finish\n", [2, 0b1110101010010000, 2]),
            ("(start)\n@start\nD=0\n@finish\n(finish)\n@start\n", [0, 0b1110101010010000, 3, 0]),
            ("(alpha)\n(beta)\n@alpha\n@beta\n", [0, 0]),
            ("@Item\n@item\n@Item\n", [16, 17, 16]),
            ("@SCREEN\n@KBD\n@fresh\n", [16384, 24576, 16]),
            ("@SP\n@LCL\n@ARG\n@THIS\n@THAT\n@fresh\n", [0, 1, 2, 3, 4, 16]),
            ("\n".join(f"@R{n}" for n in range(16)), list(range(16))),
            ("\t @0008 \r\n D = M + 1 ; JNE // ignored\r\n", [8, 0b1111110111010101]),
        ]
        for source, words in programs:
            equal(assemble(source), [f"{word:016b}" for word in words], "STATE", source)
        counts["statefulPrograms"] = len(programs)
        counts["repeatedInvocationIndependence"] = True

    return {"status": "passed", "target": "python", "counts": counts,
            "referenceRevision": provenance["revision"], "checkedFunctions": True,
            "nativeImplementation": True}


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--candidate", type=Path, required=True)
    parser.add_argument("--fixture", type=Path, required=True)
    parser.add_argument("--generated", type=Path, required=True)
    parser.add_argument("--suite", action="append", choices=["a", "c", "state"])
    arguments = parser.parse_args()
    print(json.dumps(check(arguments.candidate, arguments.fixture, arguments.generated,
                           arguments.suite or ["a", "c", "state"])))
