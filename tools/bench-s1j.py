"""Measure isolated admission/evaluation probes; JSON results are evidence, not gates."""

import argparse
import json
import os
import signal
import platform
import re
import shutil
import subprocess
import tempfile
import time

parser = argparse.ArgumentParser()
parser.add_argument("core")
parser.add_argument("--timeout", type=int, default=60)
parser.add_argument(
    "--work",
    action="store_true",
    help="measure the minimum successful logical step budget",
)
parser.add_argument(
    "--kinds",
    help="comma-separated probe kinds to run; all when omitted",
)
args = parser.parse_args()
selected = set(args.kinds.split(",")) if args.kinds else None


def probe(kind, size, source, inputs=1, cache=None):
    if selected is not None and kind not in selected:
        return
    request = {
        "schemaVersion": 5,
        "method": "check",
        "languageProfile": "1.0-rc.2",
        "verification": {
            "layers": [] if kind != "recursive" else ["exhaustive"]
        },
        "sources": [{"path": "benchmark.lawspec", "content": source}]
        if isinstance(source, str)
        else [
            {"path": f"benchmark{index}.lawspec", "content": content}
            for index, content in enumerate(source)
        ],
    }
    if cache:
        request["cacheDirectory"] = cache
    command = [
        "/usr/bin/time",
        "-l" if platform.system() == "Darwin" else "-v",
        args.core,
    ]
    start = time.monotonic()
    try:
        process = subprocess.Popen(
            command,
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            start_new_session=True,
        )
        stdout, stderr = process.communicate(
            json.dumps(request), timeout=args.timeout
        )
        response = json.loads(stdout)
        peak = re.search(r"(\d+)\s+maximum resident set size", stderr)
        if not peak:
            peak = re.search(
                r"Maximum resident set size \(kbytes\): (\d+)", stderr
            )
        cpu = re.search(r"([\d.]+) user\s+([\d.]+) sys", stderr)
        elapsed = time.monotonic() - start
        work = None
        if (
            args.work
            and kind == "recursive"
            and not response.get("diagnostics")
        ):
            low, high = 0, 1000000
            while low + 1 < high:
                middle = (low + high) // 2
                request["verification"]["evaluation"] = {"maxSteps": middle}
                measured = json.loads(
                    subprocess.check_output(
                        [args.core],
                        input=json.dumps(request),
                        text=True,
                        timeout=args.timeout,
                    )
                )
                laws = [
                    item
                    for item in measured.get("evidence", [])
                    if item.get("stage") == "law"
                ]
                if laws and all(
                    item.get("status") == "exhaustively-checked"
                    for item in laws
                ):
                    high = middle
                else:
                    low = middle
            work = high
        row = {
            "cpuSeconds": sum(map(float, cpu.groups())) if cpu else None,
            "logicalSteps": work,
            "kind": kind,
            "size": size,
            "inputs": inputs,
            "seconds": elapsed,
            "peakRssBytes": int(peak[1])
            * (1 if platform.system() == "Darwin" else 1024)
            if peak
            else None,
            "diagnostics": response.get("diagnostics", []),
            "laws": [
                {k: item[k] for k in ("status", "reason") if k in item}
                for item in response.get("evidence", [])
                if item.get("stage") == "law"
            ],
        }
    except subprocess.TimeoutExpired:
        os.killpg(process.pid, signal.SIGKILL)
        process.communicate()
        row = {"kind": kind, "size": size, "inputs": inputs, "timedOut": True}
    print(json.dumps(row), flush=True)


for width in (4, 8, 16, 32, 64):
    fields = "\n".join(f"field{i} :: Integer" for i in range(width))
    values = ", ".join(f"field{i} = x" for i in range(width))
    probe(
        "flat",
        width,
        f"unit bench\ntype Wide is a record{{{fields}}} end type\nfunction create (x :: Integer) -> Wide is Wide record{{{values}}} end function\nend unit",
    )

for depth in (4, 8, 16, 32, 64):
    types = "\n".join(
        f"type R{i} is a record{{next :: {'Integer' if i == 0 else 'R' + str(i - 1)}}} end type"
        for i in range(depth)
    )
    value = "x"
    for i in range(depth):
        value = f"R{i} record{{next = {value}}}"
    probe(
        "nested",
        depth,
        f"unit bench\n{types}\nfunction create (x :: Integer) -> R{depth - 1} is {value} end function\nend unit",
    )

# A chain of dependent bindings, each a conditional or a match over the last,
# feeding a record whose fields branch again (S1.j report 17).
def chained(name, depth):
    bindings = ["let v0 = (if x > 0 then x else 0 end if) in"]
    for i in range(1, depth):
        previous = f"v{i - 1}"
        bindings.append(
            f"let v{i} = (if {previous} > {i} then {previous} - 1 else {previous} + {previous} end if) in"
            if i % 2
            else f"let v{i} = (first matching case of [{previous}]: when Nil then {previous} when Cons head tail then head + {previous} end case) in"
        )
    values = ", ".join(
        f"field{i} = (if v{i} > 0 then v{i} else v{max(i - 1, 0)} end if)"
        for i in range(depth)
    )
    return (
        f"function {name} (x :: Integer) -> Wide{depth} is\n"
        + "\n".join(bindings)
        + f"\nWide{depth} record{{{values}}}\n"
        + " ".join(["end let"] * depth)
        + "\nend function"
    )


def wide(depth):
    fields = "\n".join(f"field{i} :: Integer" for i in range(depth))
    return f"type Wide{depth} is a record{{{fields}}} end type"


for depth in (2, 4, 6, 8, 10, 12, 14):
    probe(
        "letchain",
        depth,
        f"unit bench\n{wide(depth)}\n{chained('render', depth)}\nend unit",
    )

# The same unchanged project checked twice with one cache directory: the
# second run shows what a fresh process reuses (S1.j report 20).
for count in (8, 32):
    units = [
        f"unit bench.part{part}\n{wide(4)}\n"
        + "\n".join(chained(f"render{index}", 4) for index in range(count))
        + "\nend unit"
        for part in range(3)
    ]
    directory = tempfile.mkdtemp(prefix="lawspec-bench-cache-")
    try:
        probe("cache-cold", count, units, cache=directory)
        probe("cache-warm", count, units, cache=directory)
    finally:
        shutil.rmtree(directory, ignore_errors=True)

for depth in (4, 8, 16, 32, 64):
    for count in (1, 8, 32):
        source = f"""unit bench
function size (values :: List Bool) -> Integer is
  first matching case of values: when Nil then 0 when Cons head tail then 1 + size tail end case
end function
law length is definition:
  for all (n :: UInt8 where n < {count}) =>
    size [{", ".join(["true"] * depth)}] = {depth}
  end for all
end definition end law
end unit"""
        probe("recursive", depth, source, count)
