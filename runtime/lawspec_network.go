// The secure network handler of LawSpec's Go runtime, written beside
// lawspec_runtime.go when a program imports lawspec.network. It holds node
// identities, the handshake and sealed frames, and so needs the crypto
// libraries (crypto/mlkem, crypto/sha3, crypto/aes and
// github.com/cloudflare/circl); it registers itself with the runtime in its
// init.
package RUNTIME_PACKAGE

import (
	"bytes"
	"crypto/aes"
	"crypto/cipher"
	"crypto/mlkem"
	cryptorand "crypto/rand"
	"crypto/sha3"
	"encoding/hex"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"time"
	"unicode/utf8"

	"github.com/cloudflare/circl/sign/mldsa/mldsa65"
)

// The secure network handler (docs/reference/language/distribution.md,
// "Security"). Every node has an ML-DSA-65 identity (FIPS 204). Before two
// nodes exchange frames, the one that sends first runs a handshake: it sends
// a signed hello with a fresh ML-KEM-768 encapsulation key (FIPS 203), the
// other answers with a signed welcome carrying the ciphertext, and both
// derive an AES-256-GCM key (SP 800-38D) with SHAKE256 (FIPS 202). Frames
// then cross sealed. Records are bytes, so every transport carries them, and
// the format is the same on every target. The primitives are those of
// lawspec.crypto's default handlers: crypto/mlkem, crypto/sha3, crypto/aes
// and github.com/cloudflare/circl's ML-DSA-65.

const (
	lsRecordHello       byte = 1
	lsRecordWelcome     byte = 2
	lsRecordData        byte = 3
	lsHandshakeRetry         = 100 * time.Millisecond
	lsHandshakeDeadline      = 5 * time.Second
	lsSecureQueueLimit       = 4096
)

var (
	lsRecordMagic  = []byte{0x4C, 0x53, 0x01}
	lsLabelHello   = []byte("lawspec-handshake-v1-hello")
	lsLabelWelcome = []byte("lawspec-handshake-v1-welcome")
	lsLabelKey     = []byte("lawspec-session-v1")
	lsLabelFrame   = []byte("lawspec-frame-v1")
)

func lsNetSha3(data []byte) []byte {
	digest := sha3.Sum256(data)
	return digest[:]
}

func lsNetShake(data []byte, length int) []byte { return sha3.SumSHAKE256(data, length) }

func lsNetRandom(n int) []byte {
	out := make([]byte, n)
	if _, err := cryptorand.Read(out); err != nil {
		panic(err)
	}
	return out
}

func lsNetConcat(parts ...[]byte) []byte {
	var out []byte
	for _, part := range parts {
		out = append(out, part...)
	}
	return out
}

// lsNetField appends data as a record field: its length, then its bytes.
func lsNetField(out, data []byte) []byte {
	out = lsPutUvarint(out, uint64(len(data)))
	return append(out, data...)
}

func lsNetReadFields(data []byte, pos, count int) ([][]byte, int, bool) {
	fields := make([][]byte, 0, count)
	for i := 0; i < count; i++ {
		field, next, err := lsGetRaw(data, pos)
		if err != nil {
			return nil, pos, false
		}
		fields = append(fields, field)
		pos = next
	}
	return fields, pos, true
}

func lsNetAead(key []byte) cipher.AEAD {
	if len(key) != 32 {
		return nil
	}
	block, err := aes.NewCipher(key)
	if err != nil {
		return nil
	}
	aead, err := cipher.NewGCM(block)
	if err != nil {
		return nil
	}
	return aead
}

// LawSpecNodeIdentity is a node's long-term ML-DSA-65 identity, kept as its
// 32-byte seed.
type LawSpecNodeIdentity struct {
	seed      []byte
	private   *mldsa65.PrivateKey
	verifying []byte
}

// NewLawSpecNodeIdentity is the identity with this 32-byte ML-DSA-65 seed.
func NewLawSpecNodeIdentity(seed []byte) (*LawSpecNodeIdentity, error) {
	var xi [mldsa65.SeedSize]byte
	if len(seed) != len(xi) {
		return nil, errors.New("a node identity is a 32-byte ML-DSA-65 seed")
	}
	copy(xi[:], seed)
	public, private := mldsa65.NewKeyFromSeed(&xi)
	return &LawSpecNodeIdentity{seed: append([]byte{}, seed...), private: private, verifying: public.Bytes()}, nil
}

// LawSpecGenerateNodeIdentity is a fresh identity.
func LawSpecGenerateNodeIdentity() *LawSpecNodeIdentity {
	identity, err := NewLawSpecNodeIdentity(lsNetRandom(32))
	if err != nil {
		panic(err)
	}
	return identity
}

// LawSpecConfiguredNodeIdentity is the identity lawspec.json binds
// (lawspec-network.conf, written by the compiler), or a fresh one.
func LawSpecConfiguredNodeIdentity() *LawSpecNodeIdentity {
	if identity, _ := lsNetworkConfig(); identity != nil {
		return identity
	}
	return LawSpecGenerateNodeIdentity()
}

// Seed is the identity's 32-byte seed.
func (id *LawSpecNodeIdentity) Seed() []byte { return append([]byte{}, id.seed...) }

// VerifyingKey is the identity's ML-DSA-65 public key.
func (id *LawSpecNodeIdentity) VerifyingKey() []byte { return append([]byte{}, id.verifying...) }

// Fingerprint is SHA3-256 of the verifying key, in hexadecimal.
func (id *LawSpecNodeIdentity) Fingerprint() string {
	return hex.EncodeToString(lsNetSha3(id.verifying))
}

// Sign is a hedged ML-DSA-65 signature of message, with an empty context.
func (id *LawSpecNodeIdentity) Sign(message []byte) []byte {
	signature := make([]byte, mldsa65.SignatureSize)
	if err := mldsa65.SignTo(id.private, message, nil, true, signature); err != nil {
		panic(err)
	}
	return signature
}

func lsNetVerify(verifyingKey, message, signature []byte) bool {
	var public mldsa65.PublicKey
	if public.UnmarshalBinary(verifyingKey) != nil {
		return false
	}
	return mldsa65.Verify(&public, message, nil, signature)
}

// lsNetworkConfig reads lawspec-network.conf, which the compiler writes from
// lawspec.json's network binding: the file LAWSPEC_NETWORK_CONF names, or
// the first found in the working directory and the directories above it.
// Lines `identity <file>` (a hex seed) and `trusted <file>` (hex
// fingerprints, one per line), relative to it; `#` begins a comment. It
// gives a nil identity and nil trusted set for what it does not name.
func lsNetworkConfig() (*LawSpecNodeIdentity, map[string]bool) {
	path, named := os.LookupEnv("LAWSPEC_NETWORK_CONF")
	if !named {
		here, err := os.Getwd()
		if err != nil {
			return nil, nil
		}
		for {
			candidate := filepath.Join(here, "lawspec-network.conf")
			if _, err := os.Stat(candidate); err == nil {
				path = candidate
				break
			}
			parent := filepath.Dir(here)
			if parent == here {
				return nil, nil
			}
			here = parent
		}
	}
	if _, err := os.Stat(path); err != nil {
		return nil, nil
	}
	absolute, err := filepath.Abs(path)
	if err != nil {
		absolute = path
	}
	base := filepath.Dir(absolute)
	content, err := os.ReadFile(path)
	if err != nil {
		panic(fmt.Sprintf("cannot read %s: %v", path, err))
	}
	var identity *LawSpecNodeIdentity
	var trusted map[string]bool
	for _, line := range strings.Split(string(content), "\n") {
		line = strings.TrimSpace(line)
		words := strings.Fields(line)
		if len(words) < 2 || strings.HasPrefix(words[0], "#") {
			continue
		}
		target := strings.TrimSpace(line[len(words[0]):])
		if !filepath.IsAbs(target) {
			target = filepath.Join(base, target)
		}
		text, err := os.ReadFile(target)
		if err != nil {
			panic(fmt.Sprintf("%s: cannot read %s: %v", path, target, err))
		}
		switch words[0] {
		case "identity":
			seed, err := hex.DecodeString(strings.TrimSpace(string(text)))
			if err != nil {
				panic(fmt.Sprintf("%s: %s is not a hex seed: %v", path, target, err))
			}
			if identity, err = NewLawSpecNodeIdentity(seed); err != nil {
				panic(fmt.Sprintf("%s: %s: %v", path, target, err))
			}
		case "trusted":
			trusted = map[string]bool{}
			for _, fingerprint := range strings.Fields(string(text)) {
				trusted[strings.ToLower(fingerprint)] = true
			}
		}
	}
	return identity, trusted
}

func lsHelloBody(session []byte, address string, verifyingKey, encapsulationKey []byte) []byte {
	out := lsNetField(nil, session)
	out = lsNetField(out, []byte(address))
	out = lsNetField(out, verifyingKey)
	return lsNetField(out, encapsulationKey)
}

func lsWelcomeBody(session []byte, address string, verifyingKey, ciphertext, hello []byte) []byte {
	out := lsNetField(nil, session)
	out = lsNetField(out, []byte(address))
	out = lsNetField(out, verifyingKey)
	out = lsNetField(out, ciphertext)
	return lsNetField(out, lsNetSha3(hello))
}

// lsSessionKey is the AES-256-GCM key: SHAKE256(shared || label ||
// SHA3(hello body) || SHA3(welcome body)), 32 bytes.
func lsSessionKey(shared, hello, welcome []byte) []byte {
	return lsNetShake(lsNetConcat(shared, lsLabelKey, lsNetSha3(hello), lsNetSha3(welcome)), 32)
}

// lsSealFrame is a data record sealing frame; a nil nonce is a fresh one.
func lsSealFrame(key, session []byte, direction byte, frame, nonce []byte) []byte {
	if nonce == nil {
		nonce = lsNetRandom(12)
	}
	aead := lsNetAead(key)
	if aead == nil {
		panic("an AES-256-GCM key is 32 bytes")
	}
	associated := lsNetConcat(lsLabelFrame, session, []byte{direction})
	sealed := aead.Seal(append([]byte{}, nonce...), nonce, frame, associated)
	out := append(append([]byte{}, lsRecordMagic...), lsRecordData)
	out = lsNetField(out, session)
	out = append(out, direction)
	return lsNetField(out, sealed)
}

// lsOpenFrame is the frame a data record seals, if it opens.
func lsOpenFrame(key, record []byte) ([]byte, bool) {
	if len(record) < 4 {
		return nil, false
	}
	session, pos, ok := lsNetReadFields(record, 4, 1)
	if !ok || pos >= len(record) {
		return nil, false
	}
	direction := record[pos]
	sealed, end, ok := lsNetReadFields(record, pos+1, 1)
	if !ok || end != len(record) || len(sealed[0]) < 28 {
		return nil, false
	}
	aead := lsNetAead(key)
	if aead == nil {
		return nil, false
	}
	frame, err := aead.Open(nil, sealed[0][:12], sealed[0][12:], lsNetConcat(lsLabelFrame, session[0], []byte{direction}))
	if err != nil {
		return nil, false
	}
	if frame == nil {
		frame = []byte{}
	}
	return frame, true
}

// LawSpecHandshakeVector checks a handshake vector (hex fields, and the two
// addresses as text): the bodies' hashes, the session key and a sealed
// frame, as every target must compute them.
func LawSpecHandshakeVector(initiatorSeed, responderSeed, kemSeed, session, initiator, responder,
	ciphertext, nonce, frame, helloHash, welcomeHash, key, record string) bool {
	decoded := map[string][]byte{}
	for name, text := range map[string]string{"initiator": initiatorSeed, "responder": responderSeed, "kem": kemSeed,
		"session": session, "ciphertext": ciphertext, "nonce": nonce, "frame": frame} {
		raw, err := hex.DecodeString(text)
		if err != nil {
			return false
		}
		decoded[name] = raw
	}
	first, err := NewLawSpecNodeIdentity(decoded["initiator"])
	if err != nil {
		return false
	}
	second, err := NewLawSpecNodeIdentity(decoded["responder"])
	if err != nil {
		return false
	}
	kem, err := mlkem.NewDecapsulationKey768(decoded["kem"])
	if err != nil {
		return false
	}
	hello := lsHelloBody(decoded["session"], initiator, first.verifying, kem.EncapsulationKey().Bytes())
	welcome := lsWelcomeBody(decoded["session"], responder, second.verifying, decoded["ciphertext"], hello)
	shared, err := kem.Decapsulate(decoded["ciphertext"])
	if err != nil {
		return false
	}
	derived := lsSessionKey(shared, hello, welcome)
	if len(decoded["nonce"]) != 12 {
		return false
	}
	sealed := lsSealFrame(derived, decoded["session"], 0, decoded["frame"], decoded["nonce"])
	opened, ok := lsOpenFrame(derived, sealed)
	return hex.EncodeToString(lsNetSha3(hello)) == helloHash && hex.EncodeToString(lsNetSha3(welcome)) == welcomeHash &&
		hex.EncodeToString(derived) == key && hex.EncodeToString(sealed) == record && ok && bytes.Equal(opened, decoded["frame"])
}

type lawSpecSession struct {
	id   []byte
	peer string
	key  []byte
	// 0: this node began the handshake; 1: the peer did.
	direction byte
	// A session the peer began is used for sending once a frame has
	// arrived on it, so the peer surely holds its key.
	confirmed bool
}

type lawSpecPendingHandshake struct {
	session []byte
	kem     *mlkem.DecapsulationKey768
	body    []byte
	hello   []byte
	queue   [][]byte
	done    chan struct{}
}

type lawSpecWelcome struct {
	address string
	record  []byte
}

// lawSpecSecureLayer is the handshakes, sessions and sealed frames of one
// node.
type lawSpecSecureLayer struct {
	node     *LawSpecNode
	identity *LawSpecNodeIdentity
	// The fingerprints of the only peers to talk to, or nil for any.
	trusted  map[string]bool
	mu       sync.Mutex
	sessions map[string]*lawSpecSession
	outbound map[string]*lawSpecSession
	pending  map[string]*lawSpecPendingHandshake
	welcomes map[string]lawSpecWelcome
	// The identity first seen at each address: a later, different one is
	// refused (trust on first use, unless trusted names them).
	known map[string]string
}

// The runtime's nodes ask for their secure layer here.
func init() {
	lsSecureNetwork = func(node *LawSpecNode, identity any, trusted map[string]bool) lawSpecSecureChannel {
		return lsNewSecureLayer(node, identity, trusted)
	}
}

// lsNewSecureLayer is a node's secure layer: with this identity (a
// *LawSpecNodeIdentity, or nil for the configured one) and these trusted
// fingerprints (nil for the configured ones).
func lsNewSecureLayer(node *LawSpecNode, given any, trusted map[string]bool) *lawSpecSecureLayer {
	var identity *LawSpecNodeIdentity
	if given != nil {
		chosen, ok := given.(*LawSpecNodeIdentity)
		if !ok {
			panic(fmt.Sprintf("a node identity is a *LawSpecNodeIdentity, not %T", given))
		}
		identity = chosen
	}
	if identity == nil || trusted == nil {
		configured, configuredTrusted := lsNetworkConfig()
		if identity == nil {
			identity = configured
		}
		if trusted == nil {
			trusted = configuredTrusted
		}
	}
	if identity == nil {
		identity = LawSpecGenerateNodeIdentity()
	}
	var lowered map[string]bool
	if trusted != nil {
		lowered = map[string]bool{}
		for fingerprint, ok := range trusted {
			if ok {
				lowered[strings.ToLower(fingerprint)] = true
			}
		}
	}
	return &lawSpecSecureLayer{node: node, identity: identity, trusted: lowered,
		sessions: map[string]*lawSpecSession{}, outbound: map[string]*lawSpecSession{},
		pending: map[string]*lawSpecPendingHandshake{}, welcomes: map[string]lawSpecWelcome{}, known: map[string]string{}}
}

func (l *lawSpecSecureLayer) nodeIdentity() any { return l.identity }

// LawSpecNodeIdentityOf is a node's identity, or nil on a transport made for
// tests only.
func LawSpecNodeIdentityOf(node *LawSpecNode) *LawSpecNodeIdentity {
	identity, _ := node.Identity().(*LawSpecNodeIdentity)
	return identity
}

func (l *lawSpecSecureLayer) acceptPeer(address string, verifyingKey []byte) bool {
	fingerprint := hex.EncodeToString(lsNetSha3(verifyingKey))
	if l.trusted != nil && !l.trusted[fingerprint] {
		return false
	}
	l.mu.Lock()
	defer l.mu.Unlock()
	seen, ok := l.known[address]
	if !ok {
		l.known[address] = fingerprint
		return true
	}
	return seen == fingerprint
}

// send seals frame for peer, or queues it behind a handshake, starting one
// when none is under way. The first hello's failure is the send's.
func (l *lawSpecSecureLayer) send(peer string, frame []byte) error {
	l.mu.Lock()
	session := l.outbound[peer]
	if session == nil {
		for _, s := range l.sessions {
			if s.peer == peer && s.confirmed {
				session = s
				break
			}
		}
	}
	var pending *lawSpecPendingHandshake
	start := false
	if session == nil {
		pending = l.pending[peer]
		if pending == nil {
			pending = l.begin()
			l.pending[peer] = pending
			start = true
		}
		if len(pending.queue) < lsSecureQueueLimit {
			pending.queue = append(pending.queue, frame)
		}
	}
	l.mu.Unlock()
	if session != nil {
		return l.node.transport.Send(peer, lsSealFrame(session.key, session.id, session.direction, frame, nil))
	}
	if start {
		if err := l.node.transport.Send(peer, pending.hello); err != nil {
			l.mu.Lock()
			if l.pending[peer] == pending {
				delete(l.pending, peer)
			}
			l.mu.Unlock()
			return err
		}
		go l.retry(peer, pending)
	}
	return nil
}

func (l *lawSpecSecureLayer) begin() *lawSpecPendingHandshake {
	session := lsNetRandom(16)
	kem, err := mlkem.NewDecapsulationKey768(lsNetRandom(64))
	if err != nil {
		panic(err)
	}
	body := lsHelloBody(session, l.node.address, l.identity.verifying, kem.EncapsulationKey().Bytes())
	signature := l.identity.Sign(lsNetConcat(lsLabelHello, body))
	hello := lsNetField(lsNetConcat(lsRecordMagic, []byte{lsRecordHello}, body), signature)
	return &lawSpecPendingHandshake{session: session, kem: kem, body: body, hello: hello, done: make(chan struct{})}
}

// retry sends the hello again every lsHandshakeRetry until welcomed, the
// node closes, or lsHandshakeDeadline passes.
func (l *lawSpecSecureLayer) retry(peer string, pending *lawSpecPendingHandshake) {
	giveUp := time.Now().Add(lsHandshakeDeadline)
	ticker := time.NewTicker(lsHandshakeRetry)
	defer ticker.Stop()
	for {
		closed := false
		select {
		case <-pending.done:
			return
		case <-l.node.closed:
			closed = true
		case <-ticker.C:
		}
		if closed || !time.Now().Before(giveUp) {
			l.mu.Lock()
			if l.pending[peer] == pending {
				delete(l.pending, peer)
			}
			l.mu.Unlock()
			return
		}
		l.node.transport.Send(peer, pending.hello)
	}
}

// receive is the frame a record carries, if any: not for a handshake
// record, nor for one that fails to verify or open.
func (l *lawSpecSecureLayer) receive(record []byte) ([]byte, bool) {
	if len(record) < 4 || !bytes.Equal(record[:3], lsRecordMagic) {
		return nil, false
	}
	switch record[3] {
	case lsRecordHello:
		l.hello(record)
	case lsRecordWelcome:
		l.welcome(record)
	case lsRecordData:
		return l.data(record)
	}
	return nil, false
}

func (l *lawSpecSecureLayer) hello(record []byte) {
	fields, pos, ok := lsNetReadFields(record, 4, 4)
	if !ok {
		return
	}
	signature, end, ok := lsNetReadFields(record, pos, 1)
	if !ok || end != len(record) || !utf8.Valid(fields[1]) {
		return
	}
	session, address, verifyingKey, encapsulationKey := fields[0], string(fields[1]), fields[2], fields[3]
	body := record[4:pos]
	key := string(session)
	l.mu.Lock()
	answered, found := l.welcomes[key]
	l.mu.Unlock()
	if !found {
		if !lsNetVerify(verifyingKey, lsNetConcat(lsLabelHello, body), signature[0]) {
			return
		}
		if !l.acceptPeer(address, verifyingKey) {
			return
		}
		peerKey, err := mlkem.NewEncapsulationKey768(encapsulationKey)
		if err != nil {
			return
		}
		shared, ciphertext := peerKey.Encapsulate()
		welcome := lsWelcomeBody(session, l.node.address, l.identity.verifying, ciphertext, body)
		signed := lsNetField(lsNetConcat(lsRecordMagic, []byte{lsRecordWelcome}, welcome),
			l.identity.Sign(lsNetConcat(lsLabelWelcome, welcome)))
		l.mu.Lock()
		if _, taken := l.welcomes[key]; !taken {
			l.welcomes[key] = lawSpecWelcome{address, signed}
			l.sessions[key] = &lawSpecSession{id: append([]byte{}, session...), peer: address,
				key: lsSessionKey(shared, body, welcome), direction: 1}
		}
		answered = l.welcomes[key]
		l.mu.Unlock()
	}
	l.node.transport.Send(answered.address, answered.record)
}

func (l *lawSpecSecureLayer) welcome(record []byte) {
	fields, pos, ok := lsNetReadFields(record, 4, 5)
	if !ok {
		return
	}
	signature, end, ok := lsNetReadFields(record, pos, 1)
	if !ok || end != len(record) || !utf8.Valid(fields[1]) {
		return
	}
	session, address, verifyingKey, ciphertext, helloHash := fields[0], string(fields[1]), fields[2], fields[3], fields[4]
	l.mu.Lock()
	pending := l.pending[address]
	l.mu.Unlock()
	if pending == nil || !bytes.Equal(pending.session, session) || !bytes.Equal(helloHash, lsNetSha3(pending.body)) {
		return
	}
	body := record[4:pos]
	if !lsNetVerify(verifyingKey, lsNetConcat(lsLabelWelcome, body), signature[0]) {
		return
	}
	if !l.acceptPeer(address, verifyingKey) {
		return
	}
	shared, err := pending.kem.Decapsulate(ciphertext)
	if err != nil {
		return
	}
	key := lsSessionKey(shared, pending.body, body)
	established := &lawSpecSession{id: append([]byte{}, session...), peer: address, key: key, direction: 0, confirmed: true}
	l.mu.Lock()
	if l.pending[address] != pending {
		l.mu.Unlock()
		return
	}
	delete(l.pending, address)
	l.sessions[string(session)] = established
	l.outbound[address] = established
	queue := pending.queue
	l.mu.Unlock()
	close(pending.done)
	for _, frame := range queue {
		l.node.transport.Send(address, lsSealFrame(key, established.id, 0, frame, nil))
	}
}

func (l *lawSpecSecureLayer) data(record []byte) ([]byte, bool) {
	session, _, ok := lsNetReadFields(record, 4, 1)
	if !ok {
		return nil, false
	}
	l.mu.Lock()
	found := l.sessions[string(session[0])]
	l.mu.Unlock()
	if found == nil {
		return nil, false
	}
	frame, ok := lsOpenFrame(found.key, record)
	if ok {
		l.mu.Lock()
		found.confirmed = true
		l.mu.Unlock()
	}
	return frame, ok
}
