"""Makes the secure-transport handshake vector that every target checks (the
`the secure handshake agrees across targets` law of
examples/specs/distribution.lawspec). Run with a Python that has the
cryptography package:

    python dev/handshake-vector.py

Fixed seeds give the identities and the ephemeral ML-KEM-768 key; the
ciphertext is one encapsulation to that key (decapsulation is deterministic,
so any encapsulation serves); the frame is sealed with a fixed nonce."""
import sys

sys.path.insert(0, 'runtime')
import lawspec_runtime as ls  # noqa: E402

initiator_seed = bytes(range(32))
responder_seed = bytes(range(32, 64))
kem_seed = bytes(range(64, 128))
session = bytes(range(128, 144))
initiator, responder = 'tcp://10.0.0.1:7000', 'tcp://10.0.0.2:7000'
nonce = bytes(range(200, 212))
frame = ls._frame_encode('chan', 'end-3', initiator, 7, b'\x00\x02\x2a')

mlkem = ls._pq()[0]
kem = mlkem.MLKEM768PrivateKey.from_seed_bytes(kem_seed)
_, ciphertext = kem.public_key().encapsulate()
first, second = ls.NodeIdentity(initiator_seed), ls.NodeIdentity(responder_seed)
hello = ls.hello_body(session, initiator, first.verifying_key, kem.public_key().public_bytes_raw())
welcome = ls.welcome_body(session, responder, second.verifying_key, ciphertext, hello)
key = ls.session_key(kem.decapsulate(ciphertext), hello, welcome)
record = ls.seal_frame(key, session, 0, frame, nonce)
fields = [initiator_seed.hex(), responder_seed.hex(), kem_seed.hex(), session.hex(), initiator, responder,
          ciphertext.hex(), nonce.hex(), frame.hex(), ls._sha3(hello).hex(), ls._sha3(welcome).hex(),
          key.hex(), record.hex()]
assert ls.handshake_vector(*fields)
for f in fields:
    print(f)
