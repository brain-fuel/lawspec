"""Exchange real authenticated records between Python and a BEAM node.

The pipe carries raw transport packets so this also runs in environments
where binding a TCP listener is forbidden. It does not validate TCP/HTTP.
ref:DEC-tests-cite-requirements ref:DEC-distribution-canonical-wire
"""
import base64
import selectors
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "runtime"))
import lawspec_runtime as runtime
import lawspec_network as secure


def run(mode):
    peer = subprocess.Popen([
        "erl", "-noshell", "-pa", str(ROOT / ".artifacts/beam-runtime"), "-eval",
        f"lawspec_beam_network_peer:run({mode}).",
    ], cwd=ROOT, bufsize=0, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    ready = selectors.DefaultSelector()
    ready.register(peer.stdout, selectors.EVENT_READ)

    def read():
        assert ready.select(8), "BEAM peer timed out"
        line = peer.stdout.readline().strip()
        assert line, "BEAM peer closed unexpectedly"
        return line if line == b"done" else base64.b64decode(line, validate=True)

    def send(record):
        peer.stdin.write(base64.b64encode(record) + b"\n")
        peer.stdin.flush()

    try:
        identity = secure.NodeIdentity(bytes([1]) * 32)
        expected = secure.NodeIdentity(bytes([2]) * 32).verifying_key
        mlkem = secure._pq()[0]
        if mode == "responder":
            session = bytes(range(16))
            kem = mlkem.MLKEM768PrivateKey.from_seed_bytes(bytes(range(64)))
            hello = secure.hello_body(session, "mem://python", identity.verifying_key,
                                      kem.public_key().public_bytes_raw())
            send(b"LS\x01\x01" + hello + secure._w(identity.sign(secure._LABEL_HELLO + hello)))
            record = read()
            assert record[:4] == b"LS\x01\x02"
            fields, pos = secure._read_fields(record, 4, 5)
            (signature,), end = secure._read_fields(record, pos, 1)
            received, address, verifying_key, ciphertext, hello_hash = fields
            welcome = record[4:pos]
            assert end == len(record) and received == session and address == b"mem://beam"
            assert verifying_key == expected and hello_hash == secure._sha3(hello)
            assert secure._verify(verifying_key, secure._LABEL_WELCOME + welcome, signature)
            key = secure.session_key(kem.decapsulate(ciphertext), hello, welcome)
            frame = runtime._frame_encode("call", "echo", "mem://python", 73, b"from python")
            send(secure.seal_frame(key, session, 0, frame))
            record = read()
            assert record[:4] == b"LS\x01\x03"
            assert runtime._frame_decode(secure.open_frame(key, record)) == ["reply", "", "mem://beam", 73, b"\x00from python"]
            peer.stdin.close()
        else:
            first = read()
            assert first[:4] == b"LS\x01\x01"
            fields, pos = secure._read_fields(first, 4, 4)
            (signature,), end = secure._read_fields(first, pos, 1)
            session, address, verifying_key, encapsulation_key = fields
            hello = first[4:pos]
            assert end == len(first) and address == b"mem://beam" and verifying_key == expected
            assert secure._verify(verifying_key, secure._LABEL_HELLO + hello, signature)
            shared, ciphertext = mlkem.MLKEM768PublicKey.from_public_bytes(encapsulation_key).encapsulate()
            welcome = secure.welcome_body(session, "mem://python", identity.verifying_key, ciphertext, hello)
            answer = b"LS\x01\x02" + welcome + secure._w(identity.sign(secure._LABEL_WELCOME + welcome))
            key = secure.session_key(shared, hello, welcome)
            send(answer)
            for _ in range(100):
                record = read()
                if record == first:
                    send(answer)
                    continue
                if record == b"done":
                    break
                assert record[:4] == b"LS\x01\x03"
                kind, name, source, request, payload = runtime._frame_decode(secure.open_frame(key, record))
                assert [kind, name, source, payload] == ["call", "echo", "mem://beam", b"from beam"]
                reply = runtime._frame_encode("reply", "", "mem://python", request, b"\x00from python")
                send(secure.seal_frame(key, session, 1, reply))
            else:
                raise AssertionError("BEAM initiator did not complete its request")
        assert peer.wait(timeout=8) == 0, peer.stderr.read().decode()
        print(f"Python / BEAM secure RPC passed: BEAM {mode}")
    finally:
        ready.close()
        if peer.poll() is None:
            peer.kill()
        peer.wait()
        for stream in (peer.stdin, peer.stdout, peer.stderr):
            stream.close()


for role in ("responder", "initiator"):
    run(role)
