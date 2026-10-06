-- Built-in abilities: units under lawspec.* that declare abilities, their
-- laws and spec handlers, added to a program that imports them (see
-- docs/reference/language/builtins.md). Each ability's production handler is
-- the runtime's default handler, generated into the unit's adapter module on
-- every target (LawSpec.BuiltinDefaults); lawspec.json may bind another.
--
--   lawspec.time    Clock (with Instant), and the virtual clock
--   lawspec.randomness  Random (seeded), SecureRandom, and seeded random n
--   lawspec.crypto  Hash, KeyExchange, Signature, Aead: post-quantum by default
--   lawspec.host    FileSystem, Environment, Ports (the host machine)
--   lawspec.logging     Log, Trace
--   lawspec.concurrent   Async
--
-- lawspec.time also holds durations, added implicitly to programs that use
-- them (LawSpec.Time); its clock section joins it when a program imports it.
module LawSpec.Builtins
  ( builtinUnits, builtinSource, importsBuiltin, usesClock, clockSource, instantDefinitions
  , defaultedUnits, defaultHandlerReason, seededHandler, virtualClockHandler
  , secureRandomAbility, randomAbility, seededHandlerName, isSeededUse
  ) where

import Data.Char (isDigit)
import Data.List (isPrefixOf, stripPrefix, tails)

-- The built-in units with abilities, other than lawspec.time.
builtinUnits :: [String]
builtinUnits = ["lawspec.randomness", "lawspec.crypto", "lawspec.host", "lawspec.logging", "lawspec.concurrent"]

-- Every unit whose abilities have default handlers.
defaultedUnits :: [String]
defaultedUnits = "lawspec.time" : builtinUnits

-- Whether a source imports the unit: a line `import <unit>` (with an alias
-- or list after it, or nothing).
importsBuiltin :: String -> String -> Bool
importsBuiltin unit text = any imports (lines (stripComments text))
  where
    imports line = case words line of
      "import" : name : _ -> name == unit
      _ -> False

-- A program uses the clock when a source imports lawspec.time.
usesClock :: String -> Bool
usesClock = importsBuiltin "lawspec.time"

stripComments :: String -> String
stripComments = unlines . map takeComment . lines
  where
    takeComment line = case [i | (i, rest) <- zip [0 :: Int ..] (tails line), "--" `isPrefixOf` rest] of
      i : _ -> take i line
      [] -> line

randomAbility, secureRandomAbility :: String
randomAbility = "Random"
secureRandomAbility = "SecureRandom"

-- `seeded random n` in a law's using list: the handler seededRandom, started
-- at n. The parser writes it as this name.
seededHandlerName :: Integer -> String
seededHandlerName n = "seeded random " ++ show n

isSeededUse :: String -> Maybe Integer
isSeededUse name = case stripPrefix "seeded random " name of
  Just digits | not (null digits), all isDigit digits -> Just (read digits)
  _ -> Nothing

seededHandler, virtualClockHandler :: String
seededHandler = "seededRandom"
virtualClockHandler = "virtualClock"

-- Why evidence trusts a default handler, by ability.
defaultHandlerReason :: String -> String
defaultHandlerReason ability = "the runtime's default handler" ++ case ability of
  "Clock" -> ": the system clock, kept from going back by a monotonic clock"
  "Random" -> ": a 64-bit linear congruential generator seeded from the run's seed, as `seeded random n` is"
  "SecureRandom" -> ": the operating system's cryptographically secure generator"
  "Hash" -> ": SHA3-256 and SHAKE256 (FIPS 202), checked against NIST vectors"
  "KeyExchange" -> ": ML-KEM-768 (FIPS 203), checked against NIST ACVP vectors"
  "Signature" -> ": ML-DSA-65 (FIPS 204), checked against NIST ACVP vectors"
  "Aead" -> ": AES-256-GCM with a fresh 96-bit nonce per message, checked against NIST vectors"
  "FileSystem" -> ": the process's file system"
  "Environment" -> ": the process's environment"
  "Ports" -> ": a port the operating system reports free"
  "Log" -> ": the target's standard logger"
  "Trace" -> ": the target's standard logger, at debug level"
  "Async" -> ": the target's native threads or event loop"
  _ -> ""

-- The definitions arithmetic on instants elaborates to (LawSpec.Elaboration).
instantDefinitions :: [String]
instantDefinitions = ["valueOfInstant", "instantPlus", "instantMinus", "instantBetween"]

-- The clock: Instant, the Clock ability and the virtual clock. An instant
-- is a whole number of microseconds since 1970-01-01T00:00:00Z.
clockSource :: String
clockSource = unlines
  [ ""
  , "-- A point in time: microseconds since 1970-01-01T00:00:00Z."
  , "wrapper Instant is Int64 where value >= 0 end"
  , ""
  , "-- Instants saturate: before 1970 is 1970, and past the largest Int64"
  , "-- microsecond (the year 294247) is that microsecond."
  , "definition instantAt (micros :: Integer) :: Instant is"
  , "  if micros < 0 then Instant 0"
  , "  else if micros <= 9223372036854775807 then Instant (prelude.Int64 micros)"
  , "  else Instant 9223372036854775807"
  , "end"
  , ""
  , "definition instantPlus (t :: Instant) (d :: Duration) :: Instant is"
  , "  instantAt (valueOfInstant t + valueOfDuration d)"
  , "end"
  , ""
  , "definition instantMinus (t :: Instant) (d :: Duration) :: Instant is"
  , "  instantAt (valueOfInstant t - valueOfDuration d)"
  , "end"
  , ""
  , "definition durationAtMost (micros :: Integer) :: Duration is"
  , "  if micros <= 0 then Duration 0"
  , "  else if micros <= 4611686018426999 then Duration micros"
  , "  else Duration 4611686018426999"
  , "end"
  , ""
  , "-- The time from a to b: none when b is before a."
  , "definition instantBetween (b :: Instant) (a :: Instant) :: Duration is"
  , "  durationAtMost (valueOfInstant b - valueOfInstant a)"
  , "end"
  , ""
  , "-- The time. Every handler owes these laws."
  , "ability Clock is"
  , "  now :: Instant"
  , "  sleep :: Duration -> Unit"
  , "laws"
  , "  law `time does not go back` is"
  , "    definition is (let a = now in let b = now in valueOfInstant b >= valueOfInstant a) = true end"
  , "  end"
  , "  law `sleeping lets at least that long pass` is"
  , "    definition is"
  , "      `for all` (d :: Duration where valueOfDuration d <= 2000) ."
  , "        (let a = now in sleep d; let b = now in valueOfInstant b - valueOfInstant a >= valueOfDuration d) = true"
  , "    end"
  , "  end"
  , "end"
  , ""
  , "-- A clock that moves only when told: sleeping, or advance d, moves it at"
  , "-- once. Laws choose it with `using virtual clock`."
  , "handler virtualClock for Clock with state t :: Instant start Instant 0 is"
  , "  now is t end"
  , "  sleep d is"
  , "    ~t := instantPlus t d;"
  , "    unitValue"
  , "  end"
  , "end"
  , ""
  , "-- Let d pass. Under the virtual clock it passes at once."
  , "definition advance (d :: Duration) :: Unit uses Clock is sleep d end"
  ]

-- The source of each built-in unit with abilities, other than lawspec.time.
builtinSource :: String -> String
builtinSource unit = case unit of
  "lawspec.randomness" -> randomSource
  "lawspec.crypto" -> cryptoSource
  "lawspec.host" -> hostSource
  "lawspec.logging" -> logSource
  "lawspec.concurrent" -> asyncSource
  _ -> ""

-- Random is reproducible: the same seed gives the same draws on every
-- target. SecureRandom is the operating system's generator. They are
-- separate abilities, so a seeded source can never answer where code needs
-- a secure one, and SecureRandom has no spec handlers.
randomSource :: String
randomSource = unlines
  [ "unit lawspec.randomness"
  , ""
  , "-- One step of the generator: a 64-bit linear congruential generator"
  , "-- (Knuth's MMIX constants)."
  , "definition randomStep (s :: Integer) :: Integer is"
  , "  prelude.rem (6364136223846793005 * prelude.rem s 18446744073709551616 + 1442695040888963407) 18446744073709551616"
  , "end"
  , ""
  , "-- 64 bits from two steps: the high 32 bits of each."
  , "definition randomBits (s :: Integer) :: Integer is"
  , "  prelude.quot (randomStep s) 4294967296 * 4294967296 + prelude.quot (randomStep (randomStep s)) 4294967296"
  , "end"
  , ""
  , "definition randomClamp (r :: Integer) (bound :: Int64) :: Int64 is"
  , "  if r >= 0 && r < bound then prelude.Int64 r else 0"
  , "end"
  , ""
  , "-- A draw from 0 up to, not including, the bound; 0 when the bound is not positive."
  , "definition randomDraw (s :: Integer) (bound :: Int64) :: Int64 is"
  , "  if bound < 1 then 0 else randomClamp (prelude.rem (randomBits s) bound) bound"
  , "end"
  , ""
  , "-- Reproducible draws: the same seed gives the same draws, on every target."
  , "ability Random is"
  , "  randomBelow :: Int64 -> Int64"
  , "laws"
  , "  law `a draw is from 0 up to the bound` is"
  , "    definition is"
  , "      `for all` (n :: Int64 where n >= 1) . (let r = randomBelow n in r >= 0 && r < n) = true"
  , "    end"
  , "  end"
  , "end"
  , ""
  , "-- Draws from a seed. `seeded random n` in a law starts it at n; the"
  , "-- default handler starts at the run's seed."
  , "handler seededRandom for Random with state s :: Integer start 0 is"
  , "  randomBelow n is let r = randomDraw s n in ~s := randomStep (randomStep s); r end"
  , "end"
  , ""
  , "-- The operating system's cryptographically secure generator. No spec"
  , "-- handler can answer it: a handler written in LawSpec is predictable."
  , "ability SecureRandom is"
  , "  secureBytes :: Int32 -> Bytes"
  , "  secureBelow :: Int64 -> Int64"
  , "  secureToken :: Text"
  , "laws"
  , "  law `asking for n secure bytes gives n` is"
  , "    definition is"
  , "      `for all` (n :: Int32 where n >= 0 && n <= 4096) . prelude.length (secureBytes n) = n"
  , "    end"
  , "  end"
  , "  law `a secure draw is from 0 up to the bound` is"
  , "    definition is"
  , "      `for all` (n :: Int64 where n >= 1) . (let r = secureBelow n in r >= 0 && r < n) = true"
  , "    end"
  , "  end"
  , "  law `two secure draws of 32 bytes differ` is"
  , "    definition is (let a = secureBytes 32 in let b = secureBytes 32 in a != b) = true end"
  , "  end"
  , "  law `a token is 64 hexadecimal digits` is"
  , "    definition is prelude.length secureToken = 64 end"
  , "  end"
  , "end"
  ]

-- Post-quantum by default: SHA3-256 and SHAKE256 (FIPS 202), ML-KEM-768
-- (FIPS 203), ML-DSA-65 (FIPS 204), and AES-256-GCM. Keys, ciphertexts and
-- signatures are opaque values whose bytes are their standard encodings.
cryptoSource :: String
cryptoSource = unlines
  [ "unit lawspec.crypto"
  , ""
  , "-- A SHA3-256 digest: 32 bytes."
  , "wrapper Digest is Bytes end"
  , ""
  , "ability Hash is"
  , "  sha3 :: Bytes -> Digest"
  , "  shake :: Bytes -> Int32 -> Bytes"
  , "laws"
  , "  law `a digest is 32 bytes` is"
  , "    definition is `for all` (m :: Bytes) . prelude.length (valueOfDigest (sha3 m)) = 32 end"
  , "  end"
  , "  law `a message has one digest` is"
  , "    definition is `for all` (m :: Bytes) . valueOfDigest (sha3 m) = valueOfDigest (sha3 m) end"
  , "  end"
  , "  law `different messages have different digests` is"
  , "    definition is"
  , "      `for all` (m :: Bytes) (n :: Bytes) . m != n implies valueOfDigest (sha3 m) != valueOfDigest (sha3 n) = true"
  , "    end"
  , "  end"
  , "  law `SHAKE256 gives as many bytes as asked` is"
  , "    definition is"
  , "      `for all` (m :: Bytes) (n :: Int32 where n >= 0 && n <= 4096) . prelude.length (shake m n) = n"
  , "    end"
  , "  end"
  , "end"
  , ""
  , "-- ML-KEM-768 keys and messages, as FIPS 203 encodes them."
  , "wrapper ExchangePublicKey is Bytes end"
  , "wrapper ExchangeSecretKey is Bytes end"
  , "wrapper Ciphertext is Bytes end"
  , "wrapper SharedSecret is Bytes end"
  , "type ExchangeKeyPair is ExchangeKeyPair publicKey :: ExchangePublicKey secretKey :: ExchangeSecretKey end"
  , "type Encapsulated is Encapsulated ciphertext :: Ciphertext secret :: SharedSecret end"
  , ""
  , "-- Key encapsulation: the holder of the public key sends a ciphertext; the"
  , "-- holder of the secret key recovers the same shared secret from it."
  , "ability KeyExchange is"
  , "  exchangeKeyPair :: ExchangeKeyPair"
  , "  encapsulate :: ExchangePublicKey -> Encapsulated"
  , "  decapsulate :: ExchangeSecretKey -> Ciphertext -> SharedSecret"
  , "laws"
  , "  law `decapsulating gives the encapsulated secret` is"
  , "    definition is"
  , "      (match exchangeKeyPair with"
  , "       | ExchangeKeyPair public secret ->"
  , "           (match encapsulate public with"
  , "            | Encapsulated sent shared -> valueOfSharedSecret (decapsulate secret sent) == valueOfSharedSecret shared"
  , "            end)"
  , "       end) = true"
  , "    end"
  , "  end"
  , "  law `a shared secret is 32 bytes` is"
  , "    definition is"
  , "      (match exchangeKeyPair with"
  , "       | ExchangeKeyPair public secret ->"
  , "           (match encapsulate public with | Encapsulated sent shared -> prelude.length (valueOfSharedSecret shared) end)"
  , "       end) = 32"
  , "    end"
  , "  end"
  , "  law `another secret key gives another secret` is"
  , "    definition is"
  , "      (match exchangeKeyPair with"
  , "       | ExchangeKeyPair public secret ->"
  , "           (match exchangeKeyPair with"
  , "            | ExchangeKeyPair otherPublic otherSecret ->"
  , "                (match encapsulate public with"
  , "                 | Encapsulated sent shared -> valueOfSharedSecret (decapsulate otherSecret sent) != valueOfSharedSecret shared"
  , "                 end)"
  , "            end)"
  , "       end) = true"
  , "    end"
  , "  end"
  , "end"
  , ""
  , "-- ML-DSA-65 keys and signatures, as FIPS 204 encodes them."
  , "wrapper VerifyingKey is Bytes end"
  , "wrapper SigningKey is Bytes end"
  , "wrapper SignatureBytes is Bytes end"
  , "type SigningKeyPair is SigningKeyPair verifyingKey :: VerifyingKey signingKey :: SigningKey end"
  , ""
  , "-- Signatures: verify holds exactly when the message is the one signed and"
  , "-- the key is the signer's."
  , "ability Signature is"
  , "  signingKeyPair :: SigningKeyPair"
  , "  sign :: SigningKey -> Bytes -> SignatureBytes"
  , "  verify :: VerifyingKey -> Bytes -> SignatureBytes -> Bool"
  , "laws"
  , "  law `a signature verifies with the signer's key` is"
  , "    definition is"
  , "      `for all` (m :: Bytes) ."
  , "        (match signingKeyPair with | SigningKeyPair public secret -> verify public m (sign secret m) end) = true"
  , "    end"
  , "  end"
  , "  law `a changed message fails to verify` is"
  , "    definition is"
  , "      `for all` (m :: Bytes) (n :: Bytes) . m != n implies"
  , "        (match signingKeyPair with | SigningKeyPair public secret -> verify public n (sign secret m) end) = false"
  , "    end"
  , "  end"
  , "  law `another key's signature fails to verify` is"
  , "    definition is"
  , "      `for all` (m :: Bytes) ."
  , "        (match signingKeyPair with"
  , "         | SigningKeyPair public secret ->"
  , "             (match signingKeyPair with"
  , "              | SigningKeyPair otherPublic otherSecret -> verify public m (sign otherSecret m)"
  , "              end)"
  , "         end) = false"
  , "    end"
  , "  end"
  , "end"
  , ""
  , "-- AES-256-GCM: a 32-byte key; a sealed message is its 12-byte nonce, the"
  , "-- ciphertext and the 16-byte tag."
  , "wrapper AeadKey is Bytes end"
  , "wrapper Sealed is Bytes end"
  , ""
  , "-- Authenticated encryption with associated data. Unsealing fails (Nothing)"
  , "-- unless the key and the associated data are the ones it was sealed with."
  , "ability Aead is"
  , "  aeadKey :: AeadKey"
  , "  deriveAeadKey :: SharedSecret -> Bytes -> AeadKey"
  , "  seal :: AeadKey -> Bytes -> Bytes -> Sealed"
  , "  unseal :: AeadKey -> Sealed -> Bytes -> Maybe Bytes"
  , "laws"
  , "  law `unsealing gives what was sealed` is"
  , "    definition is"
  , "      `for all` (m :: Bytes) (a :: Bytes) . (let k = aeadKey in unseal k (seal k m a) a) = Just m"
  , "    end"
  , "  end"
  , "  law `other associated data fails to unseal` is"
  , "    definition is"
  , "      `for all` (m :: Bytes) (a :: Bytes) (b :: Bytes) . a != b implies"
  , "        (let k = aeadKey in unseal k (seal k m a) b) = Nothing"
  , "    end"
  , "  end"
  , "  law `another key fails to unseal` is"
  , "    definition is"
  , "      `for all` (m :: Bytes) . (let k = aeadKey in let other = aeadKey in unseal other (seal k m m) m) = Nothing"
  , "    end"
  , "  end"
  , "  law `a secret and a context give one key` is"
  , "    definition is"
  , "      `for all` (s :: Bytes) (c :: Bytes) ."
  , "        valueOfAeadKey (deriveAeadKey (SharedSecret s) c) = valueOfAeadKey (deriveAeadKey (SharedSecret s) c)"
  , "    end"
  , "  end"
  , "  law `an AEAD key is 32 bytes` is"
  , "    definition is"
  , "      `for all` (s :: Bytes) (c :: Bytes) . prelude.length (valueOfAeadKey (deriveAeadKey (SharedSecret s) c)) = 32"
  , "    end"
  , "  end"
  , "end"
  ]

hostSource :: String
hostSource = unlines
  [ "unit lawspec.host"
  , ""
  , "-- Files by path. A relative path is from the process's working directory."
  , "-- Each law uses a file of its own, as test runners may run laws at once."
  , "ability FileSystem is"
  , "  readBytes :: Text -> Maybe Bytes"
  , "  writeBytes :: Text -> Bytes -> Unit"
  , "  pathExists :: Text -> Bool"
  , "  removePath :: Text -> Unit"
  , "  -- A new empty directory, or file, whose name starts with the text; its path."
  , "  temporaryDirectory :: Text -> Text"
  , "  temporaryFile :: Text -> Text"
  , "laws"
  , "  law `a written file reads back` is"
  , "    definition is"
  , "      `for all` (b :: Bytes) ."
  , "        (writeBytes \".lawspec-law-read\" b; let r = readBytes \".lawspec-law-read\" in removePath \".lawspec-law-read\"; r) = Just b"
  , "    end"
  , "  end"
  , "  law `a removed file is gone` is"
  , "    definition is"
  , "      (writeBytes \".lawspec-law-removed\" (bytes([1])); removePath \".lawspec-law-removed\"; pathExists \".lawspec-law-removed\") = false"
  , "    end"
  , "  end"
  , "end"
  , ""
  , "-- Environment variables. A name that cannot be one (empty, or with = or"
  , "-- NUL in it) has no value."
  , "ability Environment is"
  , "  environmentVariable :: Text -> Maybe Text"
  , "  -- The whole environment, saved as text, and put back as saved."
  , "  environmentSnapshot :: Text"
  , "  restoreEnvironment :: Text -> Unit"
  , "laws"
  , "  law `a variable has one value` is"
  , "    definition is `for all` (n :: Text) . environmentVariable n = environmentVariable n end"
  , "  end"
  , "end"
  , ""
  , "-- An environment with no variables."
  , "handler emptyEnvironment for Environment is"
  , "  environmentVariable name is Nothing end"
  , "  environmentSnapshot is \"\" end"
  , "  restoreEnvironment saved is unitValue end"
  , "end"
  , ""
  , "-- Ports the operating system reports free."
  , "ability Ports is"
  , "  freePort :: (p :: Int32 where p >= 1 && p <= 65535)"
  , "end"
  ]

logSource :: String
logSource = unlines
  [ "unit lawspec.logging"
  , ""
  , "type LogLevel is | Debug | Info | Warning | Error end"
  , ""
  , "-- A log. The default handler writes to the target's standard logger; a"
  , "-- law that inspects what was logged uses `recording Log`."
  , "ability Log is"
  , "  logMessage :: LogLevel -> Text -> Unit"
  , "end"
  , ""
  , "-- Events of a trace."
  , "ability Trace is"
  , "  traceEvent :: Text -> Unit"
  , "end"
  , ""
  , "-- A log that drops everything."
  , "handler silentLog for Log is"
  , "  logMessage level message is unitValue end"
  , "end"
  , ""
  , "handler silentTrace for Trace is"
  , "  traceEvent name is unitValue end"
  , "end"
  ]

-- Async work. Its default handler is each target's native concurrency: a
-- pause lets other work run. (The `async` keyword's unification with this
-- ability builds on it.)
asyncSource :: String
asyncSource = unlines
  [ "unit lawspec.concurrent"
  , ""
  , "ability Async is"
  , "  pause :: Unit"
  , "laws"
  , "  law `a pause returns` is"
  , "    definition is (pause; true) = true end"
  , "  end"
  , "end"
  ]
