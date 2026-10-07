{-# LANGUAGE ScopedTypeVariables, DataKinds #-}
-- | The secure network handler of lawspec.network: node identities
-- (ML-DSA-65, FIPS 204), a signed ML-KEM-768 handshake (FIPS 203), and
-- frames sealed with AES-256-GCM (SP 800-38D) under a SHAKE256 (FIPS 202)
-- key. The compiler writes it beside LawSpecRuntime when a program imports
-- lawspec.network; install registers it with the runtime, whose nodes then
-- use it (the generated tests call it). It needs crypton, ram, mlkem and
-- mldsa, as lawspec.crypto's default handlers do.
module LawSpecNetwork
  ( install
  , NodeOptions(..), defaultNodeOptions, newNodeWith, nodeIdentity
  , NodeIdentity, identitySeed, identityVerifyingKey, nodeIdentityFromSeed, generateNodeIdentity
  , configuredNodeIdentity, identityFingerprint, identitySign, networkConfig, networkToken
  , SecureLayer, newSecureLayer, secureSend, secureReceive, secureLayer
  , helloBody, welcomeBody, sessionKey, sealRecord, sealFrame, openFrame, handshakeVector
  ) where

import Control.Concurrent (MVar, forkIO, modifyMVar, newEmptyMVar, newMVar, readMVar, tryPutMVar)
import Control.Exception (ErrorCall(..), SomeException, catch, throwIO)
import Control.Monad (foldM, forM_)
import Data.ByteString (ByteString)
import qualified Data.ByteString as B
import Data.Char (isSpace, ord, toLower)
import Data.Dynamic (fromDynamic, toDyn)
import Data.IORef (IORef, atomicModifyIORef', newIORef, readIORef, writeIORef)
import qualified Data.Map.Strict as Map
import Data.Proxy (Proxy(..))
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import Data.Unique (Unique, newUnique)
import Data.Word (Word8, Word64)
import GHC.Clock (getMonotonicTimeNSec)
import Numeric (readHex)
import System.Directory (doesFileExist, getCurrentDirectory, makeAbsolute)
import System.Environment (lookupEnv)
import System.Timeout (timeout)
import qualified Crypto.Cipher.AES as AES
import qualified Crypto.Cipher.Types as Cipher
import qualified Crypto.Error as CryptoError
import qualified Crypto.Hash as Hash
import qualified Crypto.PubKey.ML_DSA as DSA
import qualified Crypto.PubKey.ML_KEM as KEM
import qualified Crypto.Random as CryptoRandom
import qualified Data.ByteArray as BA
import LawSpecRuntime
  ( Node, NodeLayer(..), NodeTransport, SecureNetwork(..), Transport(..), Unreachable(..)
  , build, getVarint, hexOf, newNodeLayered, nodeSecure, putBytes, registerSecureNetwork )

-- | Registers this handler with the runtime: nodes made with LS.newNode
-- then run the handshake and seal their frames, and one-time tokens come
-- from crypton's secure generator. Calling it again changes nothing.
install :: IO ()
install = registerSecureNetwork (SecureNetwork
  (\transport closed -> secureLayer <$> newSecureLayer transport closed Nothing Nothing) networkToken)

-- | The runtime's view of a node's secure layer.
secureLayer :: SecureLayer -> NodeLayer
secureLayer layer = NodeLayer (secureSend layer) (secureReceive layer) (toDyn (secureIdentity layer))

-- | A node's identity (by default the one lawspec.json binds, or a fresh
-- one) and the fingerprints of the only peers it talks to (by default any
-- peer, each address keeping the first identity it shows).
data NodeOptions = NodeOptions
  { optionIdentity :: Maybe NodeIdentity
  , optionTrusted :: Maybe [String] }

defaultNodeOptions :: NodeOptions
defaultNodeOptions = NodeOptions Nothing Nothing

-- | A secure node with these options (install is not needed for it). The
-- in-memory transport made for tests only skips the handshake, as with
-- LS.newNode.
newNodeWith :: NodeTransport t => NodeOptions -> t -> IO Node
newNodeWith options = newNodeLayered (\transport closed -> secureLayer <$>
  newSecureLayer transport closed (optionIdentity options) (optionTrusted options))

-- | The node's identity (none on the insecure transport made for tests).
nodeIdentity :: Node -> Maybe NodeIdentity
nodeIdentity node = nodeSecure node >>= fromDynamic . layerIdentity

-- The secure network handler (docs/reference/language/distribution.md,
-- "Security"). Every node has an ML-DSA-65 identity (FIPS 204). Before two
-- nodes exchange frames, the one that sends first runs a handshake: it sends
-- a signed hello with a fresh ML-KEM-768 encapsulation key (FIPS 203), the
-- other answers with a signed welcome carrying the ciphertext, and both
-- derive an AES-256-GCM key (SP 800-38D) with SHAKE256 (FIPS 202). Frames
-- then cross sealed. Records are bytes, so every transport carries them, and
-- the format is the same on every target. The primitives are those of
-- lawspec.crypto's default handlers: crypton, mlkem and mldsa.

recordMagic :: ByteString
recordMagic = B.pack [0x4C, 0x53, 0x01]

recordHello, recordWelcome, recordData :: Word8
recordHello = 1
recordWelcome = 2
recordData = 3

asciiBytes :: String -> ByteString
asciiBytes = B.pack . map (fromIntegral . ord)

labelHello, labelWelcome, labelKey, labelFrame :: ByteString
labelHello = asciiBytes "lawspec-handshake-v1-hello"
labelWelcome = asciiBytes "lawspec-handshake-v1-welcome"
labelKey = asciiBytes "lawspec-session-v1"
labelFrame = asciiBytes "lawspec-frame-v1"

-- | The hello is sent again this often (microseconds) until a welcome comes,
-- for up to the deadline (nanoseconds); at most this many frames wait.
handshakeRetryMicros :: Int
handshakeRetryMicros = 100000

handshakeDeadlineNanos :: Word64
handshakeDeadlineNanos = 5000000000

handshakeQueueLimit :: Int
handshakeQueueLimit = 4096

sha3Of :: ByteString -> ByteString
sha3Of bytes = BA.convert (Hash.hashWith Hash.SHA3_256 bytes)

-- | SHAKE256, 32 bytes.
shakeKey :: ByteString -> ByteString
shakeKey bytes = BA.convert (Hash.hashFinalize (Hash.hashUpdate (Hash.hashInit :: Hash.Context (Hash.SHAKE256 256)) bytes))

-- | Bytes from the operating system's secure generator.
secureRandom :: Int -> IO ByteString
secureRandom = CryptoRandom.getRandomBytes

-- | A one-time token from the operating system's secure generator: 32 bytes
-- as 64 hexadecimal digits, as SecureRandom's secureToken gives (the
-- runtime's secureToken, once installed).
networkToken :: IO String
networkToken = hexOf <$> secureRandom 32

-- | Hexadecimal digits as bytes.
fromHex :: String -> Maybe ByteString
fromHex text
  | odd (length text) = Nothing
  | otherwise = B.pack <$> mapM byte (pairs text)
  where
    pairs (a : b : rest) = [a, b] : pairs rest
    pairs _ = []
    byte two = case readHex two of
      [(v, "")] -> Just (fromInteger v)
      _ -> Nothing

kem768 :: Proxy KEM.ML_KEM_768
kem768 = Proxy

-- | An ML-KEM-768 key pair from its 64-byte seed d || z.
kemKeys :: ByteString -> Maybe (KEM.EncapsulationKey KEM.ML_KEM_768, KEM.DecapsulationKey KEM.ML_KEM_768)
kemKeys seed
  | B.length seed /= 64 = Nothing
  | otherwise = KEM.generateWith kem768 (B.take 32 seed) (B.drop 32 seed)

-- | The ciphertext and the shared secret, for an encapsulation key.
kemEncapsulate :: ByteString -> IO (Maybe (ByteString, ByteString))
kemEncapsulate publicKey = case KEM.decode kem768 publicKey of
  Just key -> do
    (secret, ciphertext) <- KEM.encapsulate (key :: KEM.EncapsulationKey KEM.ML_KEM_768)
    pure (Just (BA.convert ciphertext, BA.convert secret))
  Nothing -> pure Nothing

kemDecapsulate :: KEM.DecapsulationKey KEM.ML_KEM_768 -> ByteString -> Maybe ByteString
kemDecapsulate key ciphertext = case KEM.decode kem768 ciphertext of
  Just sent -> Just (BA.convert (KEM.decapsulate key (sent :: KEM.Ciphertext KEM.ML_KEM_768)))
  Nothing -> Nothing

dsa65 :: Proxy DSA.ML_DSA_65
dsa65 = Proxy

-- | The empty ML-DSA context the handshake signs with.
emptyContext :: DSA.Context
emptyContext = maybe (error "the empty ML-DSA context") id (DSA.context B.empty)

dsaVerify :: ByteString -> ByteString -> ByteString -> Bool
dsaVerify publicKey message signature = maybe False id $ do
  key <- DSA.decode dsa65 publicKey
  sig <- DSA.decode dsa65 signature
  pure (DSA.verify (key :: DSA.PublicKey DSA.ML_DSA_65) message sig emptyContext)

gcmInit :: ByteString -> ByteString -> Maybe (Cipher.AEAD AES.AES256)
gcmInit key nonce
  | B.length key /= 32 || B.length nonce /= 12 = Nothing
  | otherwise = CryptoError.maybeCryptoError $ do
      cipher <- Cipher.cipherInit key
      Cipher.aeadInit Cipher.AEAD_GCM (cipher :: AES.AES256) nonce

-- | The ciphertext and its 16-byte tag.
gcmSeal :: ByteString -> ByteString -> ByteString -> ByteString -> Maybe ByteString
gcmSeal key nonce plaintext associated = do
  aead <- gcmInit key nonce
  let (tag, ciphertext) = Cipher.aeadSimpleEncrypt aead associated plaintext 16
  pure (ciphertext <> BA.convert (Cipher.unAuthTag tag))

gcmOpen :: ByteString -> ByteString -> ByteString -> ByteString -> Maybe ByteString
gcmOpen key nonce sealed associated
  | B.length sealed < 16 = Nothing
  | otherwise = do
      aead <- gcmInit key nonce
      let (ciphertext, tag) = B.splitAt (B.length sealed - 16) sealed
      Cipher.aeadSimpleDecrypt aead associated ciphertext (Cipher.AuthTag (BA.convert tag))

-- | A record field: its length in LEB128, then its bytes.
recordField :: ByteString -> ByteString
recordField = build . putBytes

-- | count fields from pos, and the position after them.
readFields :: ByteString -> Int -> Int -> Either String ([ByteString], Int)
readFields record pos0 count0 = go pos0 count0 []
  where
    go pos 0 acc = Right (reverse acc, pos)
    go pos k acc = do
      (n, p) <- getVarint record pos
      if n > toInteger (B.length record - p) then Left "a record field runs past its end"
        else go (p + fromInteger n) (k - 1 :: Int) (B.take (fromInteger n) (B.drop p record) : acc)

utf8Bytes :: String -> ByteString
utf8Bytes = TE.encodeUtf8 . T.pack

-- | A node's long-term ML-DSA-65 identity, kept as its 32-byte seed.
data NodeIdentity = NodeIdentity
  { identitySeed :: ByteString
  , identityVerifyingKey :: ByteString
  , identityKey :: DSA.PrivateKey DSA.ML_DSA_65 }

-- | The identity of a 32-byte ML-DSA-65 seed (FIPS 204 KeyGen_internal's xi).
nodeIdentityFromSeed :: ByteString -> Maybe NodeIdentity
nodeIdentityFromSeed seed
  | B.length seed /= 32 = Nothing
  | otherwise = (\(public, private) -> NodeIdentity seed (DSA.encode public) private) <$> DSA.generateWith dsa65 seed

-- | A fresh identity from the operating system's secure generator.
generateNodeIdentity :: IO NodeIdentity
generateNodeIdentity = do
  seed <- secureRandom 32
  maybe (throwIO (ErrorCall "ML-DSA-65 key generation failed")) pure (nodeIdentityFromSeed seed)

-- | The identity lawspec.json binds (lawspec-network.conf, written by the
-- compiler), or a fresh one.
configuredNodeIdentity :: IO NodeIdentity
configuredNodeIdentity = networkConfig >>= maybe generateNodeIdentity pure . fst

-- | SHA3-256 of the verifying key, in hexadecimal.
identityFingerprint :: NodeIdentity -> String
identityFingerprint = hexOf . sha3Of . identityVerifyingKey

-- | A hedged ML-DSA-65 signature, with the empty context.
identitySign :: NodeIdentity -> ByteString -> IO ByteString
identitySign identity message = DSA.encode <$> DSA.sign (identityKey identity) message emptyContext

-- | lawspec-network.conf, which the compiler writes from lawspec.json's
-- network binding: the file LAWSPEC_NETWORK_CONF names, or the first found
-- in the working directory and the directories above it. Lines `identity
-- <file>` (a hex seed) and `trusted <file>` (hex fingerprints, one per
-- line), relative to it; `#` begins a comment. The identity and the trusted
-- fingerprints it names, each if it names one.
networkConfig :: IO (Maybe NodeIdentity, Maybe [String])
networkConfig = do
  named <- lookupEnv "LAWSPEC_NETWORK_CONF"
  found <- maybe (getCurrentDirectory >>= search) (pure . Just) named
  case found of
    Nothing -> pure (Nothing, Nothing)
    Just path -> do
      exists <- doesFileExist path
      if not exists then pure (Nothing, Nothing) else do
        base <- parentDirectory <$> makeAbsolute path
        text <- readText path
        foldM (entry base) (Nothing, Nothing) (lines text)
  where
    search here = do
      let candidate = (if take 1 (reverse here) == "/" then here else here ++ "/") ++ "lawspec-network.conf"
      exists <- doesFileExist candidate
      let parent = parentDirectory here
      if exists then pure (Just candidate) else if parent == here then pure Nothing else search parent
    readText path = T.unpack . TE.decodeUtf8 <$> B.readFile path
    trim = reverse . dropWhile isSpace . reverse . dropWhile isSpace
    entry base (identity, trusted) line = do
      let (key, rest) = break isSpace (dropWhile isSpace line)
          value = trim rest
          target = if take 1 value == "/" then value else base ++ "/" ++ value
      if null key || null value || take 1 key == "#" then pure (identity, trusted) else case key of
        "identity" -> do
          text <- readText target
          case fromHex (trim text) >>= nodeIdentityFromSeed of
            Just made -> pure (Just made, trusted)
            Nothing -> throwIO (ErrorCall (target ++ " does not hold a node identity: 64 hexadecimal digits"))
        "trusted" -> do
          text <- readText target
          pure (identity, Just (map (map toLower) (words text)))
        _ -> pure (identity, trusted)

-- | The directory a path is in ("/" for the root and what is directly in it).
parentDirectory :: String -> String
parentDirectory path = case reverse (dropWhile (== '/') (dropWhile (/= '/') (reverse path))) of
  [] -> if take 1 path == "/" then "/" else path
  parent -> parent

helloBody :: ByteString -> String -> ByteString -> ByteString -> ByteString
helloBody session address verifyingKey encapsulationKey =
  B.concat [recordField session, recordField (utf8Bytes address), recordField verifyingKey, recordField encapsulationKey]

welcomeBody :: ByteString -> String -> ByteString -> ByteString -> ByteString -> ByteString
welcomeBody session address verifyingKey ciphertext hello =
  B.concat [recordField session, recordField (utf8Bytes address), recordField verifyingKey, recordField ciphertext, recordField (sha3Of hello)]

-- | The AES-256-GCM key: SHAKE256(shared || label || SHA3(hello body) ||
-- SHA3(welcome body)), 32 bytes.
sessionKey :: ByteString -> ByteString -> ByteString -> ByteString
sessionKey shared hello welcome = shakeKey (B.concat [shared, labelKey, sha3Of hello, sha3Of welcome])

-- | A data record: the frame sealed under the key with this nonce.
sealRecord :: ByteString -> ByteString -> Word8 -> ByteString -> ByteString -> Maybe ByteString
sealRecord key session direction frame nonce = do
  sealed <- gcmSeal key nonce frame (B.concat [labelFrame, session, B.singleton direction])
  pure (B.concat [recordMagic, B.singleton recordData, recordField session, B.singleton direction, recordField (nonce <> sealed)])

-- | A data record with a fresh nonce.
sealFrame :: ByteString -> ByteString -> Word8 -> ByteString -> IO ByteString
sealFrame key session direction frame = do
  nonce <- secureRandom 12
  maybe (throwIO (ErrorCall "an AES-256-GCM key is 32 bytes")) pure (sealRecord key session direction frame nonce)

-- | The frame a data record seals, or Nothing.
openFrame :: ByteString -> ByteString -> Maybe ByteString
openFrame key record = case readFields record 4 1 of
  Right ([session], pos) | pos < B.length record -> do
    let direction = B.index record pos
    case readFields record (pos + 1) 1 of
      Right ([sealed], end) | end == B.length record && B.length sealed >= 28 ->
        gcmOpen key (B.take 12 sealed) (B.drop 12 sealed) (B.concat [labelFrame, session, B.singleton direction])
      _ -> Nothing
  _ -> Nothing

-- | Checks a handshake vector (hex fields, the addresses as text): the
-- bodies' hashes, the session key and a sealed frame, as every target must
-- compute them.
handshakeVector :: String -> String -> String -> String -> String -> String -> String -> String -> String
  -> String -> String -> String -> String -> Bool
handshakeVector initiatorSeed responderSeed kemSeed session0 initiator responder ciphertext0 nonce0 frame0
    helloHash welcomeHash key record = maybe False id $ do
  first <- fromHex initiatorSeed >>= nodeIdentityFromSeed
  second <- fromHex responderSeed >>= nodeIdentityFromSeed
  (encapsulationKey, decapsulationKey) <- fromHex kemSeed >>= kemKeys
  session <- fromHex session0
  ciphertext <- fromHex ciphertext0
  nonce <- fromHex nonce0
  frame <- fromHex frame0
  let hello = helloBody session initiator (identityVerifyingKey first) (KEM.encode encapsulationKey)
      welcome = welcomeBody session responder (identityVerifyingKey second) ciphertext hello
  shared <- kemDecapsulate decapsulationKey ciphertext
  let derived = sessionKey shared hello welcome
  sealed <- sealRecord derived session 0 frame nonce
  pure (hexOf (sha3Of hello) == helloHash && hexOf (sha3Of welcome) == welcomeHash
    && hexOf derived == key && hexOf sealed == record && openFrame derived sealed == Just frame)

-- | A session: its id, the peer's address, its key, and its direction (0:
-- this node began the handshake; 1: the peer did). A session the peer began
-- is used for sending once a frame has arrived on it (confirmed), so the
-- peer surely holds its key.
data SealedSession = SealedSession
  { sealedId :: ByteString, sealedPeer :: String, sealedKey :: ByteString
  , sealedDirection :: Word8, sealedConfirmed :: IORef Bool }

-- | A handshake this node began, and the frames waiting for it (newest
-- first, with their count).
data Handshake = Handshake
  { handshakeUnique :: Unique, handshakeSession :: ByteString
  , handshakeKem :: KEM.DecapsulationKey KEM.ML_KEM_768
  , handshakeBody :: ByteString, handshakeHello :: ByteString
  , handshakeQueue :: IORef ([ByteString], Int), handshakeDone :: MVar () }

data SecureState = SecureState
  { secureSessions :: Map.Map ByteString SealedSession
  , secureOutbound :: Map.Map String SealedSession
  , securePending :: Map.Map String Handshake
  -- | The welcome sent for each session, to send again for a repeated hello.
  , secureWelcomes :: Map.Map ByteString (String, ByteString)
  -- | The identity first seen at each address: a later, different one is
  -- refused (trust on first use, unless trusted names them).
  , secureKnown :: Map.Map String String }

-- | Handshakes, sessions and sealed frames for one node.
data SecureLayer = SecureLayer
  { secureIdentity :: NodeIdentity
  , secureTrusted :: Maybe [String]
  , secureState :: MVar SecureState
  , secureTransport :: Transport
  , secureClosed :: IORef Bool }

newSecureLayer :: Transport -> IORef Bool -> Maybe NodeIdentity -> Maybe [String] -> IO SecureLayer
newSecureLayer transport closed identity trusted = do
  (configured, configuredTrust) <- case (identity, trusted) of
    (Just _, Just _) -> pure (Nothing, Nothing)
    _ -> networkConfig
  me <- maybe (maybe generateNodeIdentity pure configured) pure identity
  let trust = map (map toLower) <$> maybe configuredTrust Just trusted
  state <- newMVar (SecureState Map.empty Map.empty Map.empty Map.empty Map.empty)
  pure (SecureLayer me trust state transport closed)

acceptPeer :: SecureLayer -> String -> ByteString -> IO Bool
acceptPeer layer address verifyingKey = do
  let fingerprint = hexOf (sha3Of verifyingKey)
  if maybe False (fingerprint `notElem`) (secureTrusted layer) then pure False else
    modifyMVar (secureState layer) $ \st -> case Map.lookup address (secureKnown st) of
      Just seen -> pure (st, seen == fingerprint)
      Nothing -> pure (st { secureKnown = Map.insert address fingerprint (secureKnown st) }, True)

data SecurePlan = SendOn SealedSession | StartHandshake Handshake | Queued

-- | Sends a frame to the node at peer: sealed on its session, or queued
-- behind a handshake (whose first hello this sends, throwing Unreachable
-- as a direct send would).
secureSend :: SecureLayer -> String -> ByteString -> IO ()
secureSend layer peer frame = do
  plan <- modifyMVar (secureState layer) $ \st -> case Map.lookup peer (secureOutbound st) of
    Just session -> pure (st, SendOn session)
    Nothing -> do
      confirmed <- filterIO (readIORef . sealedConfirmed) [s | s <- Map.elems (secureSessions st), sealedPeer s == peer]
      case confirmed of
        session : _ -> pure (st, SendOn session)
        [] -> case Map.lookup peer (securePending st) of
          Just pending -> enqueue pending >> pure (st, Queued)
          Nothing -> do
            pending <- beginHandshake layer
            enqueue pending
            pure (st { securePending = Map.insert peer pending (securePending st) }, StartHandshake pending)
  case plan of
    Queued -> pure ()
    SendOn session -> sealFrame (sealedKey session) (sealedId session) (sealedDirection session) frame
      >>= transportSend (secureTransport layer) peer
    StartHandshake pending -> do
      transportSend (secureTransport layer) peer (handshakeHello pending) `catch` \(e :: Unreachable) -> do
        dropHandshake layer peer pending
        throwIO e
      () <$ forkIO (retryHandshake layer peer pending)
  where
    enqueue pending = atomicModifyIORef' (handshakeQueue pending) (\(queue, n) ->
      (if n < handshakeQueueLimit then (frame : queue, n + 1) else (queue, n), ()))
    filterIO keep = foldr (\x rest -> keep x >>= \k -> if k then (x :) <$> rest else rest) (pure [])

beginHandshake :: SecureLayer -> IO Handshake
beginHandshake layer = do
  session <- secureRandom 16
  seed <- secureRandom 64
  (encapsulationKey, decapsulationKey) <- maybe (throwIO (ErrorCall "ML-KEM-768 key generation failed")) pure (kemKeys seed)
  let me = secureIdentity layer
      body = helloBody session (transportAddress (secureTransport layer)) (identityVerifyingKey me) (KEM.encode encapsulationKey)
  signature <- identitySign me (labelHello <> body)
  unique <- newUnique
  queue <- newIORef ([], 0)
  done <- newEmptyMVar
  pure (Handshake unique session decapsulationKey body (B.concat [recordMagic, B.singleton recordHello, body, recordField signature]) queue done)

dropHandshake :: SecureLayer -> String -> Handshake -> IO ()
dropHandshake layer peer pending = modifyMVar (secureState layer) (\st ->
  pure (st { securePending = Map.update (\p -> if handshakeUnique p == handshakeUnique pending then Nothing else Just p) peer (securePending st) }, ()))

-- | Sends the hello again until a welcome comes, the node closes, or the
-- deadline passes (when the handshake and its queued frames are dropped).
retryHandshake :: SecureLayer -> String -> Handshake -> IO ()
retryHandshake layer peer pending = do
  start <- getMonotonicTimeNSec
  let loop = do
        done <- timeout handshakeRetryMicros (readMVar (handshakeDone pending))
        case done of
          Just () -> pure ()
          Nothing -> do
            closed <- readIORef (secureClosed layer)
            now <- getMonotonicTimeNSec
            if closed || now >= start + handshakeDeadlineNanos then dropHandshake layer peer pending else do
              transportSend (secureTransport layer) peer (handshakeHello pending) `catch` \(_ :: SomeException) -> pure ()
              loop
  loop

-- | The frame a record carries, or Nothing (a handshake record, or one that
-- fails to verify or open: those are dropped).
secureReceive :: SecureLayer -> ByteString -> IO (Maybe ByteString)
secureReceive layer record
  | B.length record < 4 || B.take 3 record /= recordMagic = pure Nothing
  | otherwise = (case B.index record 3 of
      kind | kind == recordHello -> Nothing <$ receiveHello layer record
           | kind == recordWelcome -> Nothing <$ receiveWelcome layer record
           | kind == recordData -> receiveData layer record
      _ -> pure Nothing) `catch` \(_ :: SomeException) -> pure Nothing

receiveHello :: SecureLayer -> ByteString -> IO ()
receiveHello layer record = case readFields record 4 4 of
  Right ([session, addressBytes, verifyingKey, encapsulationKey], pos)
    | Right ([signature], end) <- readFields record pos 1, end == B.length record
    , Right address <- T.unpack <$> TE.decodeUtf8' addressBytes -> do
        let body = B.take (pos - 4) (B.drop 4 record)
        answered <- Map.lookup session . secureWelcomes <$> readMVar (secureState layer)
        answer <- case answered of
          Just made -> pure (Just made)
          Nothing
            | not (dsaVerify verifyingKey (labelHello <> body) signature) -> pure Nothing
            | otherwise -> do
                accepted <- acceptPeer layer address verifyingKey
                encapsulated <- if accepted then kemEncapsulate encapsulationKey else pure Nothing
                case encapsulated of
                  Nothing -> pure Nothing
                  Just (ciphertext, shared) -> do
                    let me = secureIdentity layer
                        welcome = welcomeBody session (transportAddress (secureTransport layer)) (identityVerifyingKey me) ciphertext body
                    signature' <- identitySign me (labelWelcome <> welcome)
                    confirmed <- newIORef False
                    let made = (address, B.concat [recordMagic, B.singleton recordWelcome, welcome, recordField signature'])
                        session' = SealedSession session address (sessionKey shared body welcome) 1 confirmed
                    modifyMVar (secureState layer) $ \st -> case Map.lookup session (secureWelcomes st) of
                      Just earlier -> pure (st, Just earlier)
                      Nothing -> pure (st { secureWelcomes = Map.insert session made (secureWelcomes st)
                                          , secureSessions = Map.insert session session' (secureSessions st) }, Just made)
        forM_ answer $ \(to, welcome) ->
          transportSend (secureTransport layer) to welcome `catch` \(_ :: SomeException) -> pure ()
  _ -> pure ()

receiveWelcome :: SecureLayer -> ByteString -> IO ()
receiveWelcome layer record = case readFields record 4 5 of
  Right ([session, addressBytes, verifyingKey, ciphertext, helloHash], pos)
    | Right ([signature], end) <- readFields record pos 1, end == B.length record
    , Right address <- T.unpack <$> TE.decodeUtf8' addressBytes -> do
        found <- Map.lookup address . securePending <$> readMVar (secureState layer)
        case found of
          Just pending | handshakeSession pending == session, helloHash == sha3Of (handshakeBody pending) -> do
            let body = B.take (pos - 4) (B.drop 4 record)
            accepted <- if dsaVerify verifyingKey (labelWelcome <> body) signature
              then acceptPeer layer address verifyingKey else pure False
            case kemDecapsulate (handshakeKem pending) ciphertext of
              Just shared | accepted -> do
                confirmed <- newIORef True
                let key = sessionKey shared (handshakeBody pending) body
                    established = SealedSession session address key 0 confirmed
                won <- modifyMVar (secureState layer) $ \st -> case Map.lookup address (securePending st) of
                  Just current | handshakeUnique current == handshakeUnique pending -> pure (st
                    { securePending = Map.delete address (securePending st)
                    , secureSessions = Map.insert session established (secureSessions st)
                    , secureOutbound = Map.insert address established (secureOutbound st) }, True)
                  _ -> pure (st, False)
                if not won then pure () else do
                  _ <- tryPutMVar (handshakeDone pending) ()
                  (queue, _) <- readIORef (handshakeQueue pending)
                  forM_ (reverse queue) $ \frame -> (sealFrame key session 0 frame >>= transportSend (secureTransport layer) address)
                    `catch` \(_ :: SomeException) -> pure ()
              _ -> pure ()
          _ -> pure ()
  _ -> pure ()

receiveData :: SecureLayer -> ByteString -> IO (Maybe ByteString)
receiveData layer record = case readFields record 4 1 of
  Right ([session], _) -> do
    found <- Map.lookup session . secureSessions <$> readMVar (secureState layer)
    case found >>= \s -> (,) s <$> openFrame (sealedKey s) record of
      Nothing -> pure Nothing
      Just (s, frame) -> Just frame <$ writeIORef (sealedConfirmed s) True
  _ -> pure Nothing
