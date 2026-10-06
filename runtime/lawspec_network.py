"""The secure network handler of lawspec.network: node identities (ML-DSA-65,
FIPS 204), a signed ML-KEM-768 handshake (FIPS 203), and frames sealed with
AES-256-GCM (SP 800-38D) under a SHAKE256 (FIPS 202) key. The compiler
writes it beside lawspec_runtime when a program imports lawspec.network;
importing it registers it with the runtime, whose nodes then use it. It needs
the cryptography package."""
import threading

import lawspec_runtime as ls
from lawspec_runtime import Unreachable, WireError, _get_varint, _put_varint, _secure_random

# (docs/reference/language/distribution.md,
# "Security"). Every node has an ML-DSA-65 identity (FIPS 204). Before two
# nodes exchange frames, the one that sends first runs a handshake: it sends
# a signed hello with a fresh ML-KEM-768 encapsulation key (FIPS 203), the
# other answers with a signed welcome carrying the ciphertext, and both derive
# an AES-256-GCM key (SP 800-38D) with SHAKE256 (FIPS 202). Frames then cross
# sealed. Records are bytes, so every transport carries them, and the format
# is the same on every target.

_RECORD = b'LS\x01'
_HELLO, _WELCOME, _DATA = 1, 2, 3
_LABEL_HELLO = b'lawspec-handshake-v1-hello'
_LABEL_WELCOME = b'lawspec-handshake-v1-welcome'
_LABEL_KEY = b'lawspec-session-v1'
_LABEL_FRAME = b'lawspec-frame-v1'
_HANDSHAKE_RETRY = 0.1
_HANDSHAKE_DEADLINE = 5.0
_QUEUE_LIMIT = 4096


def _pq():
    try:
        from cryptography.hazmat.primitives.asymmetric import mldsa, mlkem
        from cryptography.hazmat.primitives.ciphers.aead import AESGCM
        from cryptography.exceptions import InvalidSignature, InvalidTag
    except ImportError as error:
        raise ImportError('a secure node needs the cryptography package: '
                          'python -m pip install cryptography') from error
    return mlkem, mldsa, AESGCM, InvalidSignature, InvalidTag


def _sha3(data):
    import hashlib
    return hashlib.sha3_256(data).digest()


def _shake(data, length):
    import hashlib
    return hashlib.shake_256(data).digest(length)


def _w(data):
    out = bytearray()
    _put_varint(out, len(data))
    return bytes(out) + data


def _read_fields(data, pos, count):
    fields = []
    for _ in range(count):
        n, pos = _get_varint(data, pos)
        if pos + n > len(data):
            raise WireError('a record field runs past its end')
        fields.append(bytes(data[pos:pos + n]))
        pos += n
    return fields, pos


class NodeIdentity:
    """A node's long-term ML-DSA-65 identity, kept as its 32-byte seed."""

    def __init__(self, seed):
        if len(seed) != 32:
            raise ValueError('a node identity is a 32-byte ML-DSA-65 seed')
        self.seed = bytes(seed)
        key = _pq()[1].MLDSA65PrivateKey.from_seed_bytes(self.seed)
        self._key = key
        self.verifying_key = key.public_key().public_bytes_raw()

    @staticmethod
    def generate():
        return NodeIdentity(_secure_random(32))

    @staticmethod
    def configured():
        """The identity lawspec.json binds (lawspec-network.conf, written by
        the compiler), or a fresh one."""
        identity, _ = _network_config()
        return identity if identity is not None else NodeIdentity.generate()

    @property
    def fingerprint(self):
        """SHA3-256 of the verifying key, in hexadecimal."""
        return _sha3(self.verifying_key).hex()

    def sign(self, message):
        return self._key.sign(message)


def _verify(verifying_key, message, signature):
    mldsa, invalid = _pq()[1], _pq()[3]
    try:
        mldsa.MLDSA65PublicKey.from_public_bytes(verifying_key).verify(signature, message)
        return True
    except (invalid, ValueError):
        return False


def _network_config():
    """lawspec-network.conf, which the compiler writes from lawspec.json's
    network binding: the file LAWSPEC_NETWORK_CONF names, or the first found
    in the working directory and the directories above it. Lines `identity
    <file>` (a hex seed) and `trusted <file>` (hex fingerprints, one per
    line), relative to it; `#` begins a comment."""
    import os
    path = os.environ.get('LAWSPEC_NETWORK_CONF')
    if path is None:
        here = os.getcwd()
        while True:
            candidate = os.path.join(here, 'lawspec-network.conf')
            if os.path.exists(candidate):
                path = candidate
                break
            parent = os.path.dirname(here)
            if parent == here:
                return None, None
            here = parent
    if not os.path.exists(path):
        return None, None
    base = os.path.dirname(os.path.abspath(path))
    identity, trusted = None, None
    with open(path, encoding='utf-8') as conf:
        for line in conf:
            words = line.split(None, 1)
            if len(words) != 2 or words[0].startswith('#'):
                continue
            target = os.path.join(base, words[1].strip())
            with open(target, encoding='utf-8') as f:
                text = f.read()
            if words[0] == 'identity':
                identity = NodeIdentity(bytes.fromhex(text.strip()))
            elif words[0] == 'trusted':
                trusted = {t.strip().lower() for t in text.split() if t.strip()}
    return identity, trusted


def hello_body(session, address, verifying_key, encapsulation_key):
    return _w(session) + _w(address.encode('utf-8')) + _w(verifying_key) + _w(encapsulation_key)


def welcome_body(session, address, verifying_key, ciphertext, hello):
    return _w(session) + _w(address.encode('utf-8')) + _w(verifying_key) + _w(ciphertext) + _w(_sha3(hello))


def session_key(shared, hello, welcome):
    """The AES-256-GCM key: SHAKE256(shared || label || SHA3(hello body) ||
    SHA3(welcome body)), 32 bytes."""
    return _shake(shared + _LABEL_KEY + _sha3(hello) + _sha3(welcome), 32)


def seal_frame(key, session, direction, frame, nonce=None):
    nonce = _secure_random(12) if nonce is None else nonce
    associated = _LABEL_FRAME + session + bytes([direction])
    sealed = nonce + _pq()[2](key).encrypt(nonce, frame, associated)
    return _RECORD + bytes([_DATA]) + _w(session) + bytes([direction]) + _w(sealed)


def open_frame(key, record):
    """The frame a data record seals, or None."""
    AESGCM, invalid = _pq()[2], _pq()[4]
    try:
        (session,), pos = _read_fields(record, 4, 1)
        direction = record[pos]
        (sealed,), end = _read_fields(record, pos + 1, 1)
    except (IndexError, WireError):
        return None
    if end != len(record) or len(sealed) < 28:
        return None
    try:
        return AESGCM(key).decrypt(sealed[:12], sealed[12:], _LABEL_FRAME + session + bytes([direction]))
    except invalid:
        return None


def handshake_vector(initiator_seed, responder_seed, kem_seed, session, initiator, responder,
                     ciphertext, nonce, frame, hello_hash, welcome_hash, key, record):
    """Checks a handshake vector (hex fields): the bodies' hashes, the
    session key and a sealed frame, as every target must compute them."""
    mlkem = _pq()[0]
    x = bytes.fromhex
    first, second = NodeIdentity(x(initiator_seed)), NodeIdentity(x(responder_seed))
    kem = mlkem.MLKEM768PrivateKey.from_seed_bytes(x(kem_seed))
    hello = hello_body(x(session), initiator, first.verifying_key, kem.public_key().public_bytes_raw())
    welcome = welcome_body(x(session), responder, second.verifying_key, x(ciphertext), hello)
    derived = session_key(kem.decapsulate(x(ciphertext)), hello, welcome)
    sealed = seal_frame(derived, x(session), 0, x(frame), x(nonce))
    return (_sha3(hello).hex() == hello_hash and _sha3(welcome).hex() == welcome_hash
            and derived.hex() == key and sealed.hex() == record
            and open_frame(derived, sealed) == x(frame))


class _Session:
    def __init__(self, ident, peer, key, direction, confirmed):
        self.id, self.peer, self.key = ident, peer, key
        # 0: this node began the handshake; 1: the peer did.
        self.direction = direction
        # A session the peer began is used for sending once a frame has
        # arrived on it, so the peer surely holds its key.
        self.confirmed = confirmed


class _SecureLayer:
    """Handshakes, sessions and sealed frames for one node."""

    def __init__(self, node, identity, trusted):
        self.node = node
        self.identity = identity if identity is not None else NodeIdentity.configured()
        if trusted is None:
            trusted = _network_config()[1]
        self.trusted = None if trusted is None else {t.lower() for t in trusted}
        self.sessions = {}
        self.outbound = {}
        self.pending = {}
        self.welcomes = {}
        # The identity first seen at each address: a later, different one
        # is refused (trust on first use, unless trusted names them).
        self.known = {}
        self.lock = threading.Lock()

    def _accept_peer(self, address, verifying_key):
        fingerprint = _sha3(verifying_key).hex()
        if self.trusted is not None and fingerprint not in self.trusted:
            return False
        with self.lock:
            seen = self.known.setdefault(address, fingerprint)
        return seen == fingerprint

    def send(self, peer, frame):
        with self.lock:
            session = self.outbound.get(peer)
            if session is None:
                for s in self.sessions.values():
                    if s.peer == peer and s.confirmed:
                        session = s
                        break
            if session is None:
                pending = self.pending.get(peer)
                start = pending is None
                if start:
                    pending = self.pending[peer] = self._begin(peer)
                if len(pending['queue']) < _QUEUE_LIMIT:
                    pending['queue'].append(frame)
        if session is not None:
            self.node.transport.send(peer, seal_frame(session.key, session.id, session.direction, frame))
            return
        if start:
            try:
                self.node.transport.send(peer, pending['hello'])
            except Unreachable:
                with self.lock:
                    self.pending.pop(peer, None)
                raise
            threading.Thread(target=self._retry, args=(peer, pending), daemon=True).start()

    def _begin(self, peer):
        mlkem = _pq()[0]
        session = _secure_random(16)
        kem = mlkem.MLKEM768PrivateKey.from_seed_bytes(_secure_random(64))
        body = hello_body(session, self.node.address, self.identity.verifying_key,
                          kem.public_key().public_bytes_raw())
        signature = self.identity.sign(_LABEL_HELLO + body)
        return {'session': session, 'kem': kem, 'body': body, 'queue': [], 'done': threading.Event(),
                'hello': _RECORD + bytes([_HELLO]) + body + _w(signature)}

    def _retry(self, peer, pending):
        import time
        give_up = time.monotonic() + _HANDSHAKE_DEADLINE
        while not pending['done'].wait(_HANDSHAKE_RETRY):
            if self.node.closed or time.monotonic() >= give_up:
                with self.lock:
                    if self.pending.get(peer) is pending:
                        del self.pending[peer]
                return
            try:
                self.node.transport.send(peer, pending['hello'])
            except Unreachable:
                pass

    def receive(self, record):
        """The frame a record carries, or None (a handshake record, or one
        that fails to verify or open)."""
        if len(record) < 4 or record[:3] != _RECORD:
            return None
        kind = record[3]
        try:
            if kind == _HELLO:
                self._hello(record)
            elif kind == _WELCOME:
                self._welcome(record)
            elif kind == _DATA:
                return self._data(record)
        except (WireError, IndexError, ValueError):
            return None
        return None

    def _hello(self, record):
        (session, address, verifying_key, encapsulation_key), pos = _read_fields(record, 4, 4)
        (signature,), end = _read_fields(record, pos, 1)
        if end != len(record):
            return
        body = record[4:pos]
        address = address.decode('utf-8')
        with self.lock:
            answered = self.welcomes.get(session)
        if answered is None:
            if not _verify(verifying_key, _LABEL_HELLO + body, signature):
                return
            if not self._accept_peer(address, verifying_key):
                return
            mlkem = _pq()[0]
            shared, ciphertext = mlkem.MLKEM768PublicKey.from_public_bytes(encapsulation_key).encapsulate()
            welcome = welcome_body(session, self.node.address, self.identity.verifying_key, ciphertext, body)
            answered = (address, _RECORD + bytes([_WELCOME]) + welcome +
                        _w(self.identity.sign(_LABEL_WELCOME + welcome)))
            with self.lock:
                if session not in self.welcomes:
                    self.welcomes[session] = answered
                    self.sessions[session] = _Session(session, address, session_key(shared, body, welcome), 1, False)
                answered = self.welcomes[session]
        try:
            self.node.transport.send(answered[0], answered[1])
        except Unreachable:
            pass

    def _welcome(self, record):
        (session, address, verifying_key, ciphertext, hello_hash), pos = _read_fields(record, 4, 5)
        (signature,), end = _read_fields(record, pos, 1)
        if end != len(record):
            return
        address = address.decode('utf-8')
        with self.lock:
            pending = self.pending.get(address)
        if pending is None or pending['session'] != session or hello_hash != _sha3(pending['body']):
            return
        body = record[4:pos]
        if not _verify(verifying_key, _LABEL_WELCOME + body, signature):
            return
        if not self._accept_peer(address, verifying_key):
            return
        key = session_key(pending['kem'].decapsulate(ciphertext), pending['body'], body)
        established = _Session(session, address, key, 0, True)
        with self.lock:
            if self.pending.get(address) is not pending:
                return
            del self.pending[address]
            self.sessions[session] = established
            self.outbound[address] = established
            queue = pending['queue']
        pending['done'].set()
        for frame in queue:
            try:
                self.node.transport.send(address, seal_frame(key, session, 0, frame))
            except Unreachable:
                pass

    def _data(self, record):
        (session,), _ = _read_fields(record, 4, 1)
        with self.lock:
            found = self.sessions.get(session)
        if found is None:
            return None
        frame = open_frame(found.key, record)
        if frame is not None and not found.confirmed:
            found.confirmed = True
        return frame


class _Provider:
    def layer(self, node, identity, trusted):
        return _SecureLayer(node, identity, trusted)


ls.register_secure_network(_Provider())
