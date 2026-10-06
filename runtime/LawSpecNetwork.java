package lawspec.runtime;

import java.util.ArrayList;
import java.util.Arrays;
import java.util.List;
import java.util.Map;
import lawspec.runtime.LawSpecRuntime.Node;
import lawspec.runtime.LawSpecRuntime.Transport;

/**
 * The secure network handler (docs/reference/language/distribution.md, "Security"), written beside
 * the runtime when a program imports lawspec.network. Every node has an ML-DSA-65 identity (FIPS
 * 204). Before two nodes exchange frames, the one that sends first runs a handshake: it sends a
 * signed hello with a fresh ML-KEM-768 encapsulation key (FIPS 203), the other answers with a
 * signed welcome carrying the ciphertext, and both derive an AES-256-GCM key (SP 800-38D) with
 * SHAKE256 (FIPS 202). Frames then cross sealed. Records are bytes, so every transport carries
 * them, and the format is the same on every target. ML-KEM, ML-DSA, SHA3-256 and AES-GCM come from
 * the JDK; SHAKE256 from Bouncy Castle (bcprov-jdk18on).
 *
 * <p>Its static initializer registers it with the runtime (LawSpecRuntime.registerSecureNetwork),
 * which loads this class when the first node is made.
 */
public final class LawSpecNetwork {
  private LawSpecNetwork() {}

  static {
    LawSpecRuntime.registerSecureNetwork((node, identity, trusted) -> new Layer(node, (NodeIdentity) identity, trusted));
  }

  /** A node on transport with this identity (null: the configured one, or a fresh one) and trusted peers (null: any). */
  public static Node node(Transport transport, NodeIdentity identity, java.util.Collection<String> trusted) {
    return new Node(transport, identity, trusted);
  }

  /** A node's identity; null on the insecure transport for tests. */
  public static NodeIdentity identity(Node node) {
    return (NodeIdentity) node.identity;
  }

  private static byte[] utf8(String text) {
    return text.getBytes(java.nio.charset.StandardCharsets.UTF_8);
  }

  /** A position in a record being read: LEB128 lengths and the bytes they count. */
  private static final class Reader {
    final byte[] buf;
    int pos;

    Reader(byte[] buf, int pos) {
      this.buf = buf;
      this.pos = pos;
    }

    int next() {
      if (pos >= buf.length) throw new LawSpecRuntime.WireError("a record ends in the middle of a field");
      return buf[pos++] & 0xFF;
    }

    int length() {
      long result = 0;
      for (int shift = 0; ; shift += 7) {
        int b = next();
        if (shift > 28) throw new LawSpecRuntime.WireError("a record field is too long");
        result |= (long) (b & 0x7F) << shift;
        if (b < 0x80) break;
      }
      if (result > Integer.MAX_VALUE) throw new LawSpecRuntime.WireError("a record field is too long");
      return (int) result;
    }

    byte[] take(int n) {
      if (n < 0 || n > buf.length - pos) throw new LawSpecRuntime.WireError("a record field runs past its end");
      var out = Arrays.copyOfRange(buf, pos, pos + n);
      pos += n;
      return out;
    }
  }

  private static final byte[] SECURE_RECORD = {0x4C, 0x53, 0x01};
  private static final int SECURE_HELLO = 1, SECURE_WELCOME = 2, SECURE_DATA = 3;
  private static final long HANDSHAKE_RETRY_MILLIS = 100;
  private static final long HANDSHAKE_DEADLINE_NANOS = 5_000_000_000L;
  private static final int HANDSHAKE_QUEUE_LIMIT = 4096;

  /** The labels and primitives of the secure handler, loaded with the first node. */
  private static final class SecureCrypto {
    private SecureCrypto() {}

    static final byte[] LABEL_HELLO = utf8("lawspec-handshake-v1-hello");
    static final byte[] LABEL_WELCOME = utf8("lawspec-handshake-v1-welcome");
    static final byte[] LABEL_KEY = utf8("lawspec-session-v1");
    static final byte[] LABEL_FRAME = utf8("lawspec-frame-v1");
    // The SubjectPublicKeyInfo prefixes of the standards' public keys.
    static final byte[] ML_KEM_768_SPKI = java.util.HexFormat.of().parseHex("308204b2300b0609608648016503040402038204a100");
    static final byte[] ML_DSA_65_SPKI = java.util.HexFormat.of().parseHex("308207b2300b0609608648016503040312038207a100");

    static byte[] concat(byte[]... parts) {
      var out = new java.io.ByteArrayOutputStream();
      for (var part : parts) out.writeBytes(part);
      return out.toByteArray();
    }

    /** w(x): the LEB128 length, then the bytes. */
    static byte[] w(byte[] data) {
      var out = new java.io.ByteArrayOutputStream();
      // LEB128.
      for (long n = data.length; ; n >>>= 7) {
        if (n < 0x80) {
          out.write((int) n);
          break;
        }
        out.write((int) (n & 0x7F) | 0x80);
      }
      out.writeBytes(data);
      return out.toByteArray();
    }

    static byte[] field(Reader in) {
      return in.take(in.length());
    }

    static byte[] sha3(byte[] data) {
      try {
        return java.security.MessageDigest.getInstance("SHA3-256").digest(data);
      } catch (java.security.GeneralSecurityException failed) {
        throw new IllegalStateException(failed);
      }
    }

    static byte[] shake256(byte[] data, int length) {
      return Shake.digest(data, length);
    }

    /** A source of randomness that gives these bytes, in order: how the JDK makes a key from its seed. */
    static final class Seeded extends java.security.SecureRandom {
      private final byte[] bytes;
      private int at;

      Seeded(byte[] bytes) {
        this.bytes = bytes.clone();
      }

      @Override
      public void nextBytes(byte[] out) {
        if (at + out.length > bytes.length) throw new IllegalStateException("the seed is too short");
        System.arraycopy(bytes, at, out, 0, out.length);
        at += out.length;
      }
    }

    static java.security.KeyPair keyPair(String algorithm, java.security.spec.NamedParameterSpec parameters, byte[] seed) {
      try {
        var generator = java.security.KeyPairGenerator.getInstance(algorithm);
        generator.initialize(parameters, new Seeded(seed));
        return generator.generateKeyPair();
      } catch (java.security.GeneralSecurityException failed) {
        throw new IllegalArgumentException(failed);
      }
    }

    static byte[] rawPublic(java.security.PublicKey key, int length) {
      byte[] encoded = key.getEncoded();
      return Arrays.copyOfRange(encoded, encoded.length - length, encoded.length);
    }

    static java.security.PublicKey publicKey(String algorithm, byte[] prefix, byte[] raw) throws java.security.GeneralSecurityException {
      return java.security.KeyFactory.getInstance(algorithm).generatePublic(new java.security.spec.X509EncodedKeySpec(concat(prefix, raw)));
    }

    /** An ML-KEM-768 key pair from its 64-byte seed d || z. */
    static java.security.KeyPair kemKeyPair(byte[] seed) {
      return keyPair("ML-KEM-768", java.security.spec.NamedParameterSpec.ML_KEM_768, seed);
    }

    static byte[] kemPublic(java.security.KeyPair pair) {
      return rawPublic(pair.getPublic(), 1184);
    }

    /** The ciphertext and the shared secret. */
    static byte[][] encapsulate(byte[] encapsulationKey) throws java.security.GeneralSecurityException {
      var encapsulated = javax.crypto.KEM.getInstance("ML-KEM")
          .newEncapsulator(publicKey("ML-KEM", ML_KEM_768_SPKI, encapsulationKey), secureRandom()).encapsulate();
      return new byte[][] {encapsulated.encapsulation(), encapsulated.key().getEncoded()};
    }

    static byte[] decapsulate(java.security.PrivateKey key, byte[] ciphertext) throws java.security.GeneralSecurityException {
      return javax.crypto.KEM.getInstance("ML-KEM").newDecapsulator(key).decapsulate(ciphertext).getEncoded();
    }

    static boolean verify(byte[] verifyingKey, byte[] message, byte[] signature) {
      try {
        var verifier = java.security.Signature.getInstance("ML-DSA");
        verifier.initVerify(publicKey("ML-DSA", ML_DSA_65_SPKI, verifyingKey));
        verifier.update(message);
        return verifier.verify(signature);
      } catch (java.security.GeneralSecurityException | RuntimeException failed) {
        return false;
      }
    }

    static byte[] aesGcm(int mode, byte[] key, byte[] nonce, byte[] input, byte[] associated)
        throws java.security.GeneralSecurityException {
      var cipher = javax.crypto.Cipher.getInstance("AES/GCM/NoPadding");
      cipher.init(mode, new javax.crypto.spec.SecretKeySpec(key, "AES"), new javax.crypto.spec.GCMParameterSpec(128, nonce));
      cipher.updateAAD(associated);
      return cipher.doFinal(input);
    }
  }

  /** SHAKE256 of any length, from Bouncy Castle: loaded only when a session key is derived. */
  private static final class Shake {
    private Shake() {}

    static byte[] digest(byte[] data, int length) {
      var digest = new org.bouncycastle.crypto.digests.SHAKEDigest(256);
      digest.update(data, 0, data.length);
      byte[] out = new byte[length];
      digest.doFinal(out, 0, out.length);
      return out;
    }
  }

  private static final class SecureRandomHolder {
    static final java.security.SecureRandom SECURE = new java.security.SecureRandom();
  }

  private static java.security.SecureRandom secureRandom() {
    return SecureRandomHolder.SECURE;
  }

  private static byte[] secureBytes(int n) {
    byte[] out = new byte[n];
    secureRandom().nextBytes(out);
    return out;
  }

  /** A node's long-term ML-DSA-65 identity, kept as its 32-byte seed. */
  public static final class NodeIdentity {
    private final byte[] seed;
    private final java.security.PrivateKey key;
    private final byte[] verifyingKey;

    public NodeIdentity(byte[] seed) {
      if (seed.length != 32) throw new IllegalArgumentException("a node identity is a 32-byte ML-DSA-65 seed");
      this.seed = seed.clone();
      var pair = SecureCrypto.keyPair("ML-DSA-65", java.security.spec.NamedParameterSpec.ML_DSA_65, this.seed);
      this.key = pair.getPrivate();
      this.verifyingKey = SecureCrypto.rawPublic(pair.getPublic(), 1952);
    }

    public static NodeIdentity generate() {
      return new NodeIdentity(secureBytes(32));
    }

    /** The identity lawspec.json binds (lawspec-network.conf, written by the compiler), or a fresh one. */
    public static NodeIdentity configured() {
      var identity = networkConfig().identity();
      return identity != null ? identity : generate();
    }

    public byte[] seed() {
      return seed.clone();
    }

    public byte[] verifyingKey() {
      return verifyingKey.clone();
    }

    /** SHA3-256 of the verifying key, in hexadecimal. */
    public String fingerprint() {
      return java.util.HexFormat.of().formatHex(SecureCrypto.sha3(verifyingKey));
    }

    /** An ML-DSA-65 signature (hedged, empty context) of message. */
    public byte[] sign(byte[] message) {
      try {
        var signer = java.security.Signature.getInstance("ML-DSA");
        signer.initSign(key, secureRandom());
        signer.update(message);
        return signer.sign();
      } catch (java.security.GeneralSecurityException failed) {
        throw new IllegalStateException(failed);
      }
    }
  }

  /** What lawspec-network.conf binds: an identity and trusted fingerprints, each null when not named. */
  private record NetworkConfig(NodeIdentity identity, java.util.Set<String> trusted) {}

  /**
   * lawspec-network.conf, which the compiler writes from lawspec.json's network binding: the file
   * LAWSPEC_NETWORK_CONF names, or the first found in the working directory and the directories
   * above it. Lines `identity <file>` (a hex seed) and `trusted <file>` (hex fingerprints, one per
   * line), relative to it; `#` begins a comment.
   */
  private static NetworkConfig networkConfig() {
    java.nio.file.Path path;
    String named = System.getenv("LAWSPEC_NETWORK_CONF");
    if (named != null) path = java.nio.file.Path.of(named);
    else {
      path = null;
      for (var here = java.nio.file.Path.of(System.getProperty("user.dir")).toAbsolutePath(); here != null; here = here.getParent()) {
        var candidate = here.resolve("lawspec-network.conf");
        if (java.nio.file.Files.exists(candidate)) {
          path = candidate;
          break;
        }
      }
      if (path == null) return new NetworkConfig(null, null);
    }
    if (!java.nio.file.Files.exists(path)) return new NetworkConfig(null, null);
    var base = path.toAbsolutePath().getParent();
    NodeIdentity identity = null;
    java.util.Set<String> trusted = null;
    try {
      for (var line : java.nio.file.Files.readAllLines(path, java.nio.charset.StandardCharsets.UTF_8)) {
        var words = line.strip().split("\\s+", 2);
        if (words.length != 2 || words[0].startsWith("#")) continue;
        var text = java.nio.file.Files.readString(base.resolve(words[1].strip()), java.nio.charset.StandardCharsets.UTF_8);
        if (words[0].equals("identity")) identity = new NodeIdentity(java.util.HexFormat.of().parseHex(text.strip()));
        else if (words[0].equals("trusted")) {
          trusted = new java.util.HashSet<>();
          for (var each : text.split("\\s+")) if (!each.isBlank()) trusted.add(each.strip().toLowerCase(java.util.Locale.ROOT));
        }
      }
    } catch (java.io.IOException failed) {
      throw new java.io.UncheckedIOException("cannot read " + path, failed);
    }
    return new NetworkConfig(identity, trusted);
  }

  /** A hello's body: session, address, verifying key, encapsulation key. */
  public static byte[] helloBody(byte[] session, String address, byte[] verifyingKey, byte[] encapsulationKey) {
    return SecureCrypto.concat(SecureCrypto.w(session), SecureCrypto.w(utf8(address)), SecureCrypto.w(verifyingKey),
        SecureCrypto.w(encapsulationKey));
  }

  /** A welcome's body: session, address, verifying key, ciphertext, SHA3-256 of the hello's body. */
  public static byte[] welcomeBody(byte[] session, String address, byte[] verifyingKey, byte[] ciphertext, byte[] hello) {
    return SecureCrypto.concat(SecureCrypto.w(session), SecureCrypto.w(utf8(address)), SecureCrypto.w(verifyingKey),
        SecureCrypto.w(ciphertext), SecureCrypto.w(SecureCrypto.sha3(hello)));
  }

  /** The AES-256-GCM key: SHAKE256(shared || label || SHA3(hello body) || SHA3(welcome body)), 32 bytes. */
  public static byte[] sessionKey(byte[] shared, byte[] hello, byte[] welcome) {
    return SecureCrypto.shake256(SecureCrypto.concat(shared, SecureCrypto.LABEL_KEY, SecureCrypto.sha3(hello),
        SecureCrypto.sha3(welcome)), 32);
  }

  /** A data record sealing frame; a fresh nonce when nonce is null. */
  public static byte[] sealFrame(byte[] key, byte[] session, int direction, byte[] frame, byte[] nonce) {
    if (nonce == null) nonce = secureBytes(12);
    byte[] associated = SecureCrypto.concat(SecureCrypto.LABEL_FRAME, session, new byte[] {(byte) direction});
    byte[] sealed;
    try {
      sealed = SecureCrypto.concat(nonce, SecureCrypto.aesGcm(javax.crypto.Cipher.ENCRYPT_MODE, key, nonce, frame, associated));
    } catch (java.security.GeneralSecurityException failed) {
      throw new IllegalStateException(failed);
    }
    return SecureCrypto.concat(SECURE_RECORD, new byte[] {(byte) SECURE_DATA}, SecureCrypto.w(session),
        new byte[] {(byte) direction}, SecureCrypto.w(sealed));
  }

  /** The frame a data record seals, or null. */
  public static byte[] openFrame(byte[] key, byte[] record) {
    try {
      var in = new Reader(record, 4);
      byte[] session = SecureCrypto.field(in);
      int direction = in.next();
      byte[] sealed = SecureCrypto.field(in);
      if (in.pos != record.length || sealed.length < 28) return null;
      byte[] associated = SecureCrypto.concat(SecureCrypto.LABEL_FRAME, session, new byte[] {(byte) direction});
      return SecureCrypto.aesGcm(javax.crypto.Cipher.DECRYPT_MODE, key, Arrays.copyOf(sealed, 12),
          Arrays.copyOfRange(sealed, 12, sealed.length), associated);
    } catch (java.security.GeneralSecurityException | RuntimeException failed) {
      return null;
    }
  }

  /**
   * Checks a handshake vector (hex fields, the addresses as text): the bodies' hashes, the session
   * key and a sealed frame, as every target must compute them.
   */
  public static boolean handshakeVector(
      String initiatorSeed, String responderSeed, String kemSeed, String session, String initiator, String responder,
      String ciphertext, String nonce, String frame, String helloHash, String welcomeHash, String key, String record) {
    var hex = java.util.HexFormat.of();
    var first = new NodeIdentity(hex.parseHex(initiatorSeed));
    var second = new NodeIdentity(hex.parseHex(responderSeed));
    var kem = SecureCrypto.kemKeyPair(hex.parseHex(kemSeed));
    byte[] hello = helloBody(hex.parseHex(session), initiator, first.verifyingKey, SecureCrypto.kemPublic(kem));
    byte[] welcome = welcomeBody(hex.parseHex(session), responder, second.verifyingKey, hex.parseHex(ciphertext), hello);
    byte[] derived;
    try {
      derived = sessionKey(SecureCrypto.decapsulate(kem.getPrivate(), hex.parseHex(ciphertext)), hello, welcome);
    } catch (java.security.GeneralSecurityException failed) {
      return false;
    }
    byte[] sealed = sealFrame(derived, hex.parseHex(session), 0, hex.parseHex(frame), hex.parseHex(nonce));
    return hex.formatHex(SecureCrypto.sha3(hello)).equals(helloHash)
        && hex.formatHex(SecureCrypto.sha3(welcome)).equals(welcomeHash)
        && hex.formatHex(derived).equals(key)
        && hex.formatHex(sealed).equals(record)
        && Arrays.equals(openFrame(derived, sealed), hex.parseHex(frame));
  }

  /** A session between two nodes. */
  private static final class SecureSession {
    final byte[] id;
    final String peer;
    final byte[] key;
    // 0: this node began the handshake; 1: the peer did.
    final int direction;
    // A session the peer began is used for sending once a frame has arrived
    // on it, so the peer surely holds its key.
    volatile boolean confirmed;

    SecureSession(byte[] id, String peer, byte[] key, int direction, boolean confirmed) {
      this.id = id;
      this.peer = peer;
      this.key = key;
      this.direction = direction;
      this.confirmed = confirmed;
    }
  }

  /** A handshake this node began: frames wait in queue until the welcome. */
  private static final class PendingHandshake {
    final byte[] session;
    final java.security.PrivateKey kem;
    final byte[] body;
    final byte[] hello;
    final List<byte[]> queue = new ArrayList<>();
    final java.util.concurrent.CountDownLatch done = new java.util.concurrent.CountDownLatch(1);

    PendingHandshake(byte[] session, java.security.PrivateKey kem, byte[] body, byte[] hello) {
      this.session = session;
      this.kem = kem;
      this.body = body;
      this.hello = hello;
    }
  }

  /** A welcome already sent for a session: its address and record, sent again for a repeated hello. */
  private record Answered(String address, byte[] record) {}

  /** Handshakes, sessions and sealed frames for one node. */
  private static final class Layer implements LawSpecRuntime.SecureLayer {
    private final Node node;
    final NodeIdentity identity;
    private final java.util.Set<String> trusted;
    private final Map<String, SecureSession> sessions = new java.util.HashMap<>();
    private final Map<String, SecureSession> outbound = new java.util.HashMap<>();
    private final Map<String, PendingHandshake> pending = new java.util.HashMap<>();
    private final Map<String, Answered> welcomes = new java.util.HashMap<>();
    // The identity first seen at each address: a later, different one is
    // refused (trust on first use, unless trusted names them).
    private final Map<String, String> known = new java.util.HashMap<>();

    Layer(Node node, NodeIdentity identity, java.util.Collection<String> trusted) {
      this.node = node;
      this.identity = identity != null ? identity : NodeIdentity.configured();
      java.util.Collection<String> named = trusted != null ? trusted : networkConfig().trusted();
      if (named == null) this.trusted = null;
      else {
        var set = new java.util.HashSet<String>();
        for (var each : named) set.add(each.toLowerCase(java.util.Locale.ROOT));
        this.trusted = set;
      }
    }

    @Override
    public Object identity() {
      return identity;
    }

    private static String key(byte[] session) {
      return java.util.HexFormat.of().formatHex(session);
    }

    private boolean acceptPeer(String address, byte[] verifyingKey) {
      String fingerprint = java.util.HexFormat.of().formatHex(SecureCrypto.sha3(verifyingKey));
      if (trusted != null && !trusted.contains(fingerprint)) return false;
      synchronized (this) {
        String seen = known.putIfAbsent(address, fingerprint);
        return seen == null || seen.equals(fingerprint);
      }
    }

    @Override
    public void send(String peer, byte[] frame) {
      SecureSession session = null;
      PendingHandshake handshake = null;
      boolean start = false;
      synchronized (this) {
        session = outbound.get(peer);
        if (session == null) {
          for (var each : sessions.values()) {
            if (each.peer.equals(peer) && each.confirmed) {
              session = each;
              break;
            }
          }
        }
        if (session == null) {
          handshake = pending.get(peer);
          start = handshake == null;
          if (start) {
            handshake = begin();
            pending.put(peer, handshake);
          }
          if (handshake.queue.size() < HANDSHAKE_QUEUE_LIMIT) handshake.queue.add(frame);
        }
      }
      if (session != null) {
        node.transport.send(peer, sealFrame(session.key, session.id, session.direction, frame, null));
        return;
      }
      if (start) {
        try {
          node.transport.send(peer, handshake.hello);
        } catch (RuntimeException unreachable) {
          synchronized (this) {
            pending.remove(peer, handshake);
          }
          throw unreachable;
        }
        var begun = handshake;
        Thread.ofVirtual().start(() -> retry(peer, begun));
      }
    }

    private PendingHandshake begin() {
      byte[] session = secureBytes(16);
      var kem = SecureCrypto.kemKeyPair(secureBytes(64));
      byte[] body = helloBody(session, node.address, identity.verifyingKey, SecureCrypto.kemPublic(kem));
      byte[] signature = identity.sign(SecureCrypto.concat(SecureCrypto.LABEL_HELLO, body));
      byte[] hello = SecureCrypto.concat(SECURE_RECORD, new byte[] {(byte) SECURE_HELLO}, body, SecureCrypto.w(signature));
      return new PendingHandshake(session, kem.getPrivate(), body, hello);
    }

    /** Sends the hello again every 100 ms until welcomed, for up to 5 s. */
    private void retry(String peer, PendingHandshake handshake) {
      long giveUp = System.nanoTime() + HANDSHAKE_DEADLINE_NANOS;
      while (true) {
        try {
          if (handshake.done.await(HANDSHAKE_RETRY_MILLIS, java.util.concurrent.TimeUnit.MILLISECONDS)) return;
        } catch (InterruptedException e) {
          Thread.currentThread().interrupt();
          return;
        }
        if (node.closed || System.nanoTime() - giveUp >= 0) {
          synchronized (this) {
            pending.remove(peer, handshake);
          }
          return;
        }
        try {
          node.transport.send(peer, handshake.hello);
        } catch (RuntimeException unreachable) {
          // Sent again on the next round.
        }
      }
    }

    /** The frame a record carries, or null (a handshake record, or one that fails to verify or open). */
    @Override
    public byte[] receive(byte[] record) {
      if (record.length < 4 || record[0] != SECURE_RECORD[0] || record[1] != SECURE_RECORD[1] || record[2] != SECURE_RECORD[2])
        return null;
      try {
        switch (record[3]) {
          case SECURE_HELLO -> hello(record);
          case SECURE_WELCOME -> welcome(record);
          case SECURE_DATA -> {
            return data(record);
          }
          default -> {}
        }
      } catch (java.security.GeneralSecurityException | RuntimeException dropped) {
        return null;
      }
      return null;
    }

    private static String address(byte[] raw) {
      try {
        return java.nio.charset.StandardCharsets.UTF_8.newDecoder()
            .onMalformedInput(java.nio.charset.CodingErrorAction.REPORT)
            .onUnmappableCharacter(java.nio.charset.CodingErrorAction.REPORT)
            .decode(java.nio.ByteBuffer.wrap(raw)).toString();
      } catch (java.nio.charset.CharacterCodingException e) {
        throw new LawSpecRuntime.WireError("an address that is not UTF-8");
      }
    }

    private void hello(byte[] record) throws java.security.GeneralSecurityException {
      var in = new Reader(record, 4);
      byte[] session = SecureCrypto.field(in);
      String address = address(SecureCrypto.field(in));
      byte[] verifyingKey = SecureCrypto.field(in);
      byte[] encapsulationKey = SecureCrypto.field(in);
      int pos = in.pos;
      byte[] signature = SecureCrypto.field(in);
      if (in.pos != record.length) return;
      byte[] body = Arrays.copyOfRange(record, 4, pos);
      String id = key(session);
      Answered answered;
      synchronized (this) {
        answered = welcomes.get(id);
      }
      if (answered == null) {
        if (!SecureCrypto.verify(verifyingKey, SecureCrypto.concat(SecureCrypto.LABEL_HELLO, body), signature)) return;
        if (!acceptPeer(address, verifyingKey)) return;
        byte[][] encapsulated = SecureCrypto.encapsulate(encapsulationKey);
        byte[] welcome = welcomeBody(session, node.address, identity.verifyingKey, encapsulated[0], body);
        var made = new Answered(address, SecureCrypto.concat(SECURE_RECORD, new byte[] {(byte) SECURE_WELCOME}, welcome,
            SecureCrypto.w(identity.sign(SecureCrypto.concat(SecureCrypto.LABEL_WELCOME, welcome)))));
        byte[] derived = sessionKey(encapsulated[1], body, welcome);
        synchronized (this) {
          if (!welcomes.containsKey(id)) {
            welcomes.put(id, made);
            sessions.put(id, new SecureSession(session, address, derived, 1, false));
          }
          answered = welcomes.get(id);
        }
      }
      try {
        node.transport.send(answered.address(), answered.record());
      } catch (RuntimeException unreachable) {
        // The peer sends its hello again.
      }
    }

    private void welcome(byte[] record) throws java.security.GeneralSecurityException {
      var in = new Reader(record, 4);
      byte[] session = SecureCrypto.field(in);
      String address = address(SecureCrypto.field(in));
      byte[] verifyingKey = SecureCrypto.field(in);
      byte[] ciphertext = SecureCrypto.field(in);
      byte[] helloHash = SecureCrypto.field(in);
      int pos = in.pos;
      byte[] signature = SecureCrypto.field(in);
      if (in.pos != record.length) return;
      PendingHandshake handshake;
      synchronized (this) {
        handshake = pending.get(address);
      }
      if (handshake == null || !Arrays.equals(handshake.session, session)
          || !Arrays.equals(helloHash, SecureCrypto.sha3(handshake.body))) return;
      byte[] body = Arrays.copyOfRange(record, 4, pos);
      if (!SecureCrypto.verify(verifyingKey, SecureCrypto.concat(SecureCrypto.LABEL_WELCOME, body), signature)) return;
      if (!acceptPeer(address, verifyingKey)) return;
      byte[] derived = sessionKey(SecureCrypto.decapsulate(handshake.kem, ciphertext), handshake.body, body);
      var established = new SecureSession(session, address, derived, 0, true);
      List<byte[]> queue;
      synchronized (this) {
        if (pending.get(address) != handshake) return;
        pending.remove(address);
        sessions.put(key(session), established);
        outbound.put(address, established);
        queue = new ArrayList<>(handshake.queue);
      }
      handshake.done.countDown();
      for (var frame : queue) {
        try {
          node.transport.send(address, sealFrame(derived, session, 0, frame, null));
        } catch (RuntimeException unreachable) {
          // The sender sends again.
        }
      }
    }

    private byte[] data(byte[] record) {
      byte[] session = SecureCrypto.field(new Reader(record, 4));
      SecureSession found;
      synchronized (this) {
        found = sessions.get(key(session));
      }
      if (found == null) return null;
      byte[] frame = openFrame(found.key, record);
      if (frame != null && !found.confirmed) found.confirmed = true;
      return frame;
    }
  }
}
