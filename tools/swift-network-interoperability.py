"""Exchange values between a Python node and a Swift node over TCP.

Both nodes run their own runtime's secure transport (the ML-KEM and ML-DSA
handshake, then sealed records), so this checks the shared wire format live
across two targets, not only against recorded vectors. Python serves mailbox
`python`, Swift serves mailbox `swift`: Swift sends 41, Python answers 100,
and Swift sends back 101. ref:DEC-tests-cite-requirements
ref:DEC-distribution-canonical-wire
"""
import shutil
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "runtime"))
import lawspec_network  # noqa: F401  (registers the secure layer)
import lawspec_runtime as runtime

DESCRIPTOR = runtime.read_descriptor("(int Int64 -9223372036854775808 9223372036854775807)")[0]
PACKAGE = """// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "NetworkPeer",
    platforms: [.macOS(.v26)],
    targets: [
        .target(name: "LawSpecRuntime", path: "LawSpecRuntime"),
        .executableTarget(name: "NetworkPeer", dependencies: ["LawSpecRuntime"], path: "Peer"),
    ]
)
"""


def build():
    """The Swift peer, built over the runtime's sources."""
    package = ROOT / ".artifacts/swift-network-peer"
    shutil.rmtree(package / "LawSpecRuntime", ignore_errors=True)
    shutil.copytree(ROOT / "runtime/swift/LawSpecRuntime", package / "LawSpecRuntime")
    (package / "Peer").mkdir(parents=True, exist_ok=True)
    shutil.copy(ROOT / "test/fixtures/swift/NetworkPeer.swift", package / "Peer/main.swift")
    (package / "Package.swift").write_text(PACKAGE)
    subprocess.run(["swift", "build", "--product", "NetworkPeer"], cwd=package, check=True,
                   stdout=subprocess.DEVNULL)
    return package / ".build/debug/NetworkPeer"


def main():
    peer_binary = build()
    node = runtime.Node(runtime.TcpTransport())
    inbox = node.mailbox("python", DESCRIPTOR)
    peer = subprocess.Popen([str(peer_binary), f"{node.address}/python"], stdout=subprocess.PIPE,
                            stderr=subprocess.PIPE, text=True)
    try:
        first = peer.stdout.readline().split()
        assert first[:1] == ["address"], f"Swift peer did not start: {first} {peer.stderr.read()}"
        assert inbox.receive(timeout=20) == 41, "Swift's first value"
        node.remote_mailbox(first[1], DESCRIPTOR, timeout=10.0).send(100)
        assert inbox.receive(timeout=20) == 101, "Swift's answer"
        last = peer.stdout.readline().split()
        assert last == ["done", "100"], f"Swift peer: {last} {peer.stderr.read()}"
        assert peer.wait(timeout=20) == 0
    finally:
        if peer.poll() is None:
            peer.kill()
        node.close()
    print("Python and Swift nodes exchanged values over TCP through the secure transport.")


if __name__ == "__main__":
    main()
