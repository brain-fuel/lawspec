-- | The tar archives of contract packages: a reader for what lawspec fetch
-- unpacks (git archive's output and published .tgz files) and a writer for
-- what lawspec package publishes, each as the node-tar 7 options
-- component-packages.mjs used.
--
-- The reader decodes ustar and pax headers ('x' and 'g' records for path,
-- linkpath and size) and GNU long names ('L', 'N', 'K'), validates every
-- header checksum, and reports the first malformed header or truncated body
-- with node-tar's strict-mode message. It does not touch the file system:
-- 'unpackEntries' returns the files and directories to create, with the
-- permission bits node-tar 7.5.22's extract gives them, and refuses
-- the whole archive when any entry is unsafe — an absolute path, a @..@
-- component, a path that resolves outside the root, or any entry other
-- than a regular file or directory (links, devices, FIFOs). Entry types
-- node-tar skips (vendor extensions it does not know) are skipped.
--
-- The writer emits node-tar's portable layout for regular files: ustar
-- headers with node-tar's octal formatting, each file's mode as
-- 'portableMode' records it, uid, gid, user and group names
-- left empty, mtime 0, the path split between name and prefix as node-tar
-- splits it, and a pax header (path, mtime, size) where the path cannot be
-- stored in the ustar fields; then two zero blocks.
-- ref:DEC-haskell-application-port
module LawSpec.Archive.Tar
  ( Entry (..),
    EntryType (..),
    readTar,
    Unpacked (..),
    unpackEntries,
    writeTar,
    portableMode,
  )
where

import Data.Bits (complement, shiftL, (.&.), (.|.))
import qualified Data.ByteString as B
import qualified Data.ByteString.Char8 as BC
import Data.Char (chr, isDigit, ord)
import Data.List (isPrefixOf, isSuffixOf)
import Data.Maybe (fromMaybe)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import qualified Data.Text.Encoding.Error as TE
import LawSpec.Host.Path (resolve, within)

data EntryType
  = RegularFile
  | OldFile
  | ContiguousFile
  | Directory
  | HardLink
  | SymbolicLink
  | CharacterDevice
  | BlockDevice
  | Fifo
  | DumpDirectory
  deriving (Eq, Show)

-- | One file-system entry of an archive, with its pax and GNU overrides
-- applied.
data Entry = Entry
  { entryPath :: String,
    entryType :: EntryType,
    -- | The mode node-tar's ReadEntry ends with: a pax mode (the global
    -- header's over the entry's), else the header's mode field, masked to
    -- 0o7777 unless it is 0; 'Nothing' when the field is not a number.
    entryMode :: Maybe Integer,
    entryBody :: B.ByteString
  }
  deriving (Eq, Show)

-- | Extended-header fields that apply to the next entry ('x', 'L', 'K') or
-- to all later ones ('g').
data Extended = Extended
  { extendedPath :: Maybe String,
    extendedLinkpath :: Maybe String,
    extendedSize :: Maybe Integer,
    extendedMode :: Maybe Integer
  }

noExtended :: Extended
noExtended = Extended Nothing Nothing Nothing Nothing

-- | node-tar's Buffer#toString('utf8').
utf8 :: B.ByteString -> String
utf8 = T.unpack . TE.decodeUtf8With TE.lenientDecode

encodeUtf8 :: String -> B.ByteString
encodeUtf8 = TE.encodeUtf8 . T.pack

-- | decString: the field's text up to its first NUL.
field :: B.ByteString -> Int -> Int -> String
field block offset size = takeWhile (/= '\0') (utf8 (B.take size (B.drop offset block)))

-- | decNumber: base-256 when the high bit is set, else octal text.
number :: B.ByteString -> Int -> Int -> Maybe Integer
number block offset size
  | B.index raw 0 .&. 0x80 /= 0 = Just (base256 raw)
  | otherwise = parseOctal (trim (takeWhile (/= '\0') (utf8 raw)))
  where
    raw = B.take size (B.drop offset block)
    trim = reverse . dropWhile (`elem` (" \t\n\r" :: String)) . reverse . dropWhile (`elem` (" \t\n\r" :: String))
    -- parseInt(text, 8): an optional sign, then the longest octal prefix.
    parseOctal text = case text of
      '-' : rest -> negate <$> digits rest
      '+' : rest -> digits rest
      _ -> digits text
    digits text = case takeWhile (`elem` ("01234567" :: String)) text of
      [] -> Nothing
      ds -> Just (foldl (\acc d -> acc * 8 + fromIntegral (ord d - 48)) 0 ds)
    base256 bytes =
      let value = foldl (\acc b -> acc * 256 + fromIntegral b) 0 (B.unpack bytes) :: Integer
          bits = 8 * B.length bytes
       in if B.index bytes 0 == 0xff then value - (1 `shiftL` bits) else value - (1 `shiftL` (bits - 1))

-- | The pax records node-tar reads: "<length> <key>=<value>\n" lines whose
-- length is right.
paxRecords :: String -> Extended -> Extended
paxRecords body previous = foldl apply previous (lines' body)
  where
    lines' text = case break (== '\n') (stripFinal text) of
      (line, []) -> [line]
      (line, _ : rest) -> line : lines' rest
    stripFinal text = if "\n" `isSuffixOf` text then init text else text
    apply ex line =
      let (lengthText, rest) = span isDigit line
       in case (reads lengthText :: [(Int, String)], rest) of
            ([(n, "")], ' ' : record)
              | n == B.length (encodeUtf8 line) + 1 ->
                  let (key, value0) = break (== '=') record
                      value = takeWhile (/= '\0') (drop 1 value0)
                   in case key of
                        "path" -> ex {extendedPath = Just value}
                        "linkpath" -> ex {extendedLinkpath = Just value}
                        "size" -> case reads value of
                          [(size, "")] | size >= 0 -> ex {extendedSize = Just size}
                          _ -> ex
                        "mode" -> ex {extendedMode = Just (javascriptInteger value)}
                        _ -> ex
            _ -> ex

-- | @+value@ as a 32-bit integer, as a bitwise operator sees it: decimal,
-- or 0x, 0o or 0b digits, around white space; anything else is NaN, which
-- is 0. Fractions are truncated.
javascriptInteger :: String -> Integer
javascriptInteger text = case trimmed of
  "" -> 0
  '0' : base : digits
    | base `elem` ("xX" :: String) -> radix 16 digits
    | base `elem` ("oO" :: String) -> radix 8 digits
    | base `elem` ("bB" :: String) -> radix 2 digits
  '-' : rest -> negate (decimal rest)
  '+' : rest -> decimal rest
  _ -> decimal trimmed
  where
    trimmed = reverse (dropWhile (`elem` (" \t\n\r\f\v" :: String)) (reverse (dropWhile (`elem` (" \t\n\r\f\v" :: String)) text)))
    radix base digits
      | not (null digits), Just values <- mapM (value base) digits = foldl (\acc d -> acc * base + d) 0 values
      | otherwise = 0
    value base c =
      let d
            | isDigit c = toInteger (ord c - 48)
            | c >= 'a' && c <= 'f' = toInteger (ord c - 87)
            | c >= 'A' && c <= 'F' = toInteger (ord c - 55)
            | otherwise = 99
       in if d < base then Just d else Nothing
    decimal digits = case reads digits :: [(Double, String)] of
      [(number', "")] | not (isNaN number' || isInfinite number') -> truncate number'
      _ -> case span isDigit digits of
        (whole@(_ : _), "") -> read whole
        (whole@(_ : _), '.' : fraction) | all isDigit fraction -> read whole
        ("", '.' : fraction@(_ : _)) | all isDigit fraction -> 0
        _ -> 0

-- | Every file-system entry of a tar archive, in order; or node-tar's
-- strict-mode error. Entries of a type node-tar ignores are left out.
readTar :: B.ByteString -> Either String [Entry]
readTar archive = go 0 False noExtended noExtended False []
  where
    total = B.length archive
    go position sawNull ex gex sawValid acc
      | position + 512 > total = finish sawValid acc
      | otherwise =
          let block = B.take 512 (B.drop position archive)
              cksumField = number block 148 12
              typeChar = field block 156 1
              normal = typeChar `elem` ["0", "", "1", "2", "3", "4", "5", "6", "7", "D"]
              exFields = if normal then ex else noExtended
              gexFields = if normal then gex else noExtended
              sum' = 8 * 0x20 + sum (map fromIntegral (B.unpack (B.take 148 block))) + sum (map fromIntegral (B.unpack (B.drop 156 block))) :: Integer
              nullBlock = cksumField == Nothing && sum' == 8 * 0x20
           in if nullBlock
                then
                  if sawNull
                    then finish sawValid acc
                    else go (position + 512) True ex gex sawValid acc
                else
                  if cksumField /= Just sum'
                    then Left "TAR_ENTRY_INVALID: checksum failure"
                    else entry position block typeChar exFields gexFields ex gex acc
    entry position block typeChar exFields gexFields ex gex acc =
      let code = if typeChar `elem` codes then (if null typeChar then "0" else typeChar) else "Unsupported"
          headerPath = fromMaybe (field block 0 100) (extendedPath exFields)
          code' = if code == "0" && "/" `isSuffixOf` headerPath then "5" else code
          ustar = B.take 8 (B.drop 257 block) == BC.pack "ustar\NUL00"
          prefixed
            | not ustar = headerPath
            | B.index block 475 /= 0 = field block 345 155 ++ "/" ++ headerPath
            | otherwise = let prefix = field block 345 130 in if null prefix then headerPath else prefix ++ "/" ++ headerPath
          size0 = case extendedSize exFields of
            Just given -> Just given
            Nothing -> case extendedSize gexFields of
              Just given -> Just given
              Nothing -> number block 124 12
          size = if code' == "5" then 0 else maybe 0 (max 0) (nonNegative size0)
          nonNegative value = case value of
            Just n | n >= 0 -> Just n
            _ -> Nothing
          linkpath = field block 157 100
          -- Header: the pax modes, else the field; ReadEntry masks a
          -- non-zero header mode, then takes the entry's pax mode and the
          -- global header's over it.
          headerMode = case extendedMode exFields of
            Just given -> Just given
            Nothing -> case extendedMode gexFields of
              Just given -> Just given
              Nothing -> number block 100 8
          masked = fmap (\value -> if value /= 0 then value .&. 0o7777 else value) headerMode
          mode = case (extendedMode gex, extendedMode ex) of
            (Just given, _) -> Just given
            (Nothing, Just given) -> Just given
            _ -> masked
          name = typeName code'
          isLink = name `elem` ["Link", "SymbolicLink"]
          path' = fromMaybe prefixed (extendedPath ex)
          bodyStart = position + 512
          blockLength = 512 * ((size + 511) `div` 512)
          available = toInteger (total - bodyStart)
          body = B.take (fromInteger size) (B.drop bodyStart archive)
          next = bodyStart + fromInteger blockLength
       in if null prefixed
            then Left "TAR_ENTRY_INVALID: path is required"
            else
              if isLink && null linkpath
                then Left "TAR_ENTRY_INVALID: linkpath required"
                else
                  if not isLink && name `notElem` ["ExtendedHeader", "GlobalExtendedHeader"] && not (null linkpath)
                    then Left "TAR_ENTRY_INVALID: linkpath forbidden"
                    else
                      if blockLength > available
                        then Left ("TAR_BAD_ARCHIVE: Truncated input (needed " ++ show (blockLength - max 0 available) ++ " more bytes, only 0 available)")
                        else
                          let text = utf8 body
                              meta = name `elem` ["ExtendedHeader", "OldExtendedHeader", "GlobalExtendedHeader", "NextFileHasLongPath", "OldGnuLongPath", "NextFileHasLongLinkpath"]
                           in if meta
                                then
                                  if size > 1024 * 1024 || size == 0
                                    then go next False ex gex True acc
                                    else case name of
                                      "GlobalExtendedHeader" -> go next False ex (paxRecords text gex) True acc
                                      "NextFileHasLongLinkpath" -> go next False ex {extendedLinkpath = Just (takeWhile (/= '\0') text)} gex True acc
                                      "NextFileHasLongPath" -> go next False ex {extendedPath = Just (takeWhile (/= '\0') text)} gex True acc
                                      "OldGnuLongPath" -> go next False ex {extendedPath = Just (takeWhile (/= '\0') text)} gex True acc
                                      _ -> go next False (paxRecords text ex) gex True acc
                                else case fileType name of
                                  Nothing -> go next False noExtended gex True acc
                                  Just kind -> go next False noExtended gex True (Entry path' kind mode body : acc)
    finish sawValid acc
      | not sawValid = Left "TAR_BAD_ARCHIVE: Unrecognized archive format"
      | otherwise = Right (reverse acc)
    codes = ["0", "", "1", "2", "3", "4", "5", "6", "7", "g", "x", "A", "D", "I", "K", "L", "M", "N", "S", "V", "X"]
    typeName code = fromMaybe "Unsupported" (lookup code names)
    names =
      [ ("0", "File"),
        ("1", "Link"),
        ("2", "SymbolicLink"),
        ("3", "CharacterDevice"),
        ("4", "BlockDevice"),
        ("5", "Directory"),
        ("6", "FIFO"),
        ("7", "ContiguousFile"),
        ("g", "GlobalExtendedHeader"),
        ("x", "ExtendedHeader"),
        ("A", "SolarisACL"),
        ("D", "GNUDumpDir"),
        ("I", "Inode"),
        ("K", "NextFileHasLongLinkpath"),
        ("L", "NextFileHasLongPath"),
        ("M", "ContinuationFile"),
        ("N", "OldGnuLongPath"),
        ("S", "SparseFile"),
        ("V", "TapeVolumeHeader"),
        ("X", "OldExtendedHeader")
      ]
    fileType name = lookup name kinds
    kinds =
      [ ("File" :: String, RegularFile),
        ("OldFile", OldFile),
        ("ContiguousFile", ContiguousFile),
        ("Directory", Directory),
        ("Link", HardLink),
        ("SymbolicLink", SymbolicLink),
        ("CharacterDevice", CharacterDevice),
        ("BlockDevice", BlockDevice),
        ("FIFO", Fifo),
        ("GNUDumpDir", DumpDirectory)
      ]

-- | What unpacking into a directory creates, in archive order: a
-- directory (absolute) or a file (absolute, with its bytes), each with the
-- permission bits node-tar creates it with, before the file-creation mask;
-- a later file of the same path replaces an earlier one.
data Unpacked = MakeDirectory FilePath Int | MakeFile FilePath Int B.ByteString
  deriving (Eq, Show)

-- | component-packages.mjs unpack(): the archive's entries below the
-- directory, or "Unsafe package archive entry: <name>" naming the last
-- unsafe entry when any is.
unpackEntries :: FilePath -> [Entry] -> Either String [Unpacked]
unpackEntries directory entries = case [entryPath e | e <- entries, unsafe e] of
  [] -> Right (place [] entries)
  refused -> Left ("Unsafe package archive entry: " ++ last refused)
  where
    -- node-tar opens a file with its mode, or 0666; a directory with its
    -- mode, or 0777, and the owner's bits always. A file it writes again
    -- is opened over the first, which keeps its bits.
    place _ [] = []
    place seen (e : rest)
      | entryType e == Directory = MakeDirectory target (fromInteger (maybe 0o777 (.&. 0o7777) (entryMode e)) .|. 0o700) : place seen rest
      | otherwise =
          let bits = fromMaybe (fromInteger (maybe 0o666 (.&. 0o7777) (entryMode e))) (lookup target seen)
           in MakeFile target bits (entryBody e) : place ((target, bits) : seen) rest
      where
        target = resolve directory (entryPath e)
    unsafe e =
      "/" `isPrefixOf` entryPath e
        || ".." `elem` components (entryPath e)
        || not (within directory (resolve directory (entryPath e)))
        || entryType e `notElem` [RegularFile, Directory, OldFile, ContiguousFile]
    components text = case break (`elem` ("/\\" :: String)) text of
      (part, []) -> [part]
      (part, _ : rest) -> part : components rest

-- | modeFix with portable set, for a file: the permission bits with the
-- owner's read and write added and the group's and others' write removed,
-- so 0755 and 0700 stay, 0775 is 0755 and 0664 is 0644.
-- ref:node-tar-mode-fix
portableMode :: Int -> Int
portableMode bits = ((bits .&. 0o7777) .|. 0o600) .&. complement 0o22

-- | node-tar's portable archive of regular files: each path (relative,
-- with forward slashes), its mode ('portableMode'), and its bytes; then the
-- end blocks.
writeTar :: [(String, Int, B.ByteString)] -> B.ByteString
writeTar files = B.concat (concatMap entry files ++ [B.replicate 1024 0])
  where
    entry (path', mode, body) =
      let (block, needPax) = header path' mode (toInteger (B.length body)) '0'
          pax =
            [ let records = paxField "path" path' ++ paxField "mtime" "0" ++ paxField "size" (show (B.length body))
                  recordBytes = encodeUtf8 records
                  (paxBlock, _) = header (take 99 ("PaxHeader/" ++ baseName path')) 0o644 (toInteger (B.length recordBytes)) 'x'
               in B.concat [paxBlock, pad recordBytes]
            | needPax
            ]
       in pax ++ [block] ++ [pad body | not (B.null body)]
    pad bytes = B.append bytes (B.replicate ((512 - B.length bytes `mod` 512) `mod` 512) 0)

-- | Pax.encodeField: " key=value\n" behind its own length in digits.
paxField :: String -> String -> String
paxField key value =
  let record = " " ++ key ++ "=" ++ value ++ "\n"
      byteLength = B.length (encodeUtf8 record)
      digits0 = length (show byteLength)
      digits = if byteLength + digits0 >= 10 ^ digits0 then digits0 + 1 else digits0
   in show (digits + byteLength) ++ record

-- | Header.encode for a portable entry with mtime 0: the block and whether
-- a pax header must precede it.
header :: String -> Int -> Integer -> Char -> (B.ByteString, Bool)
header path' mode size typeFlag =
  let (name, prefix, split) = splitPrefix path'
      (nameBytes, nameOver) = string 100 name
      (prefixBytes, prefixOver) = string 155 prefix
      sizeOver = size > 0o77777777777
      fields =
        [ nameBytes,
          octal 8 (toInteger mode),
          B.replicate 8 0,
          B.replicate 8 0,
          if sizeOver then B.replicate 12 0 else octal 12 size,
          octal 12 0,
          BC.pack "        ",
          B.singleton (fromIntegral (ord typeFlag)),
          B.replicate 100 0,
          BC.pack "ustar\NUL00",
          B.replicate 32 0,
          B.replicate 32 0,
          octal 8 0,
          octal 8 0,
          prefixBytes,
          B.replicate 12 0
        ]
      unsummed = B.concat fields
      checksum = sum (map fromIntegral (B.unpack unsummed)) :: Integer
      block = B.concat [B.take 148 unsummed, octal 8 checksum, B.drop 156 unsummed]
   in (block, split || nameOver || prefixOver || sizeOver)
  where
    -- encString: the UTF-8 characters that fit, NUL-padded; over when the
    -- text is not ASCII or has more UTF-16 units than the field's size.
    string width text =
      let fitting = takeFitting width text
          units = sum [if ord c >= 0x10000 then 2 else 1 | c <- text]
       in (B.append fitting (B.replicate (width - B.length fitting) 0), any ((> 127) . ord) text || units > width)
    takeFitting width = go B.empty
      where
        go acc [] = acc
        go acc (c : rest) =
          let bytes = encodeUtf8 [c]
           in if B.length acc + B.length bytes > width then acc else go (B.append acc bytes) rest

-- | padOctal: octal digits zero-padded, then a space and a NUL; or the
-- digits and a NUL when they fill all but one byte.
octal :: Int -> Integer -> B.ByteString
octal size value =
  let digits = showOctal value
      text =
        if length digits == size - 1
          then digits ++ "\0"
          else replicate (size - length digits - 2) '0' ++ digits ++ " \0"
   in BC.pack (take size text)
  where
    showOctal 0 = "0"
    showOctal n = reverse (go n)
      where
        go 0 = ""
        go k = chr (48 + fromInteger (k `mod` 8)) : go (k `div` 8)

-- | node-tar's splitPrefix with the 155-byte prefix of a portable header:
-- the name, the prefix, and whether the path could not be split.
splitPrefix :: String -> (String, String, Bool)
splitPrefix path'
  | byteLength path' < 100 = (path', "", False)
  | otherwise = loop (baseName path') (dirName path')
  where
    root = "."
    loop name prefix
      | byteLength name <= 100 && byteLength prefix <= 155 = (name, prefix, False)
      | byteLength name > 100 && byteLength prefix <= 155 = (take 99 name, prefix, True)
      | otherwise =
          let name' = joinPosix (baseName prefix) name
              prefix' = dirName prefix
           in if prefix' == root then (take 99 path', "", True) else loop name' prefix'
    byteLength = B.length . encodeUtf8

-- | path.posix.basename and dirname for the relative, slash-separated
-- paths of a package.
baseName :: String -> String
baseName text = reverse (takeWhile (/= '/') (reverse (stripTrailing text)))

dirName :: String -> String
dirName text = case reverse (drop 1 (dropWhile (/= '/') (reverse (stripTrailing text)))) of
  [] -> if "/" `isPrefixOf` text then "/" else "."
  parent -> parent

stripTrailing :: String -> String
stripTrailing text = case reverse (dropWhile (== '/') (reverse text)) of
  [] -> if null text then "" else "/"
  kept -> kept

joinPosix :: String -> String -> String
joinPosix left right
  | null left || left == "." = right
  | otherwise = left ++ "/" ++ right
