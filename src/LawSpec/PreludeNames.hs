-- | The public prelude value namespace. Inference and the existing checked
-- definitions remain authoritative for types, effects and contracts.
-- Internal execution helpers are not public source names.
module LawSpec.PreludeNames
  ( simplePreludeHelpers, sequencePreludeHelpers, preludeValueName
  , preludeDiscoveryText, preludeDependencyText ) where

import qualified LawSpec.Core as C
import LawSpec.Collections (canonicalCollectionOperations)
import LawSpec.Matchers (matcherOperations)
import LawSpec.Time (timeOperations)
import LawSpec.Railway (railwayNames)
import LawSpec.Scalar (isNumeric)
import LawSpec.SourceText (Token(..),TokenKind(..),sourceTokens)
import Data.List (nub,stripPrefix)

simplePreludeHelpers :: [(String,C.Builtin)]
simplePreludeHelpers =
  [("length",C.Length),("isPresent",C.IsPresent),("presentValue",C.PresentValue),("real",C.RealPart),("imag",C.ImaginaryPart)
  ,("isNaN",C.IsNaN),("isInfinite",C.IsInfinite),("isFinite",C.IsFinite),("isNegativeZero",C.IsNegativeZero),("round",C.RoundHalfEven),("checked",C.Checked)
  ,("compare",C.Compare),("select",C.Select),("unreachable",C.Unreachable),("concurrently",C.Concurrently)]

sequencePreludeHelpers :: [(String,C.Builtin)]
sequencePreludeHelpers =
  [("octets",C.Octets),("bytesOf",C.BytesOf),("utf8",C.Utf8),("textOf",C.TextOf),("join",C.Join)]

preludeValueName :: String -> Bool
preludeValueName name = isNumeric name || name `elem` publicNames
  where
    publicNames = map fst simplePreludeHelpers ++ map fst sequencePreludeHelpers ++
      map fst canonicalCollectionOperations ++ map fst matcherOperations ++ map fst timeOperations ++ railwayNames ++
      ["any","member","contains","startsWith","endsWith","regexMatches","within","messageContains","recorded","caseFold","textContains"
      ,"toList","size","isEmpty","quot","rem","pow","wrapping","saturating","bounded"
      ,"raise","attempt","calls","append","slice","take","drop","at","range"]

-- Discovery precedes parsing. These are dependency hints, never a rewrite of
-- the user's document or a decision about what a name denotes. Shadowed names
-- may load an unused provider; lexical/local/import resolution still wins.
-- Keep comments, strings and phrase bodies out of the hints.
preludeDiscoveryText :: String -> String
preludeDiscoveryText text = text ++ "\n" ++ preludeDependencyText text

-- Operation demand is independent of a user's same-spelled type declaration.
-- Providers can be loaded without importing their type names unqualified.
preludeDependencyText :: String -> String
preludeDependencyText text = unwords ["prelude." ++ name | name <- nub candidates]
  where
    tokens = [token | token <- sourceTokens text,tokenKind token `notElem` [TriviaToken,CommentToken]]
    candidates = [name | (previous,token) <- zip (Nothing:map Just tokens) tokens,
      name <- case tokenKind token of
        WordToken | maybe True ((/= ".") . tokenText) previous -> [tokenText token]
        PhraseToken | Just ordinary <- stripPrefix "`" (tokenText token),take 1 ordinary /= "|" ->
          [maybe ordinary id (stripPrefix "prelude." ordinary)]
        _ -> [],preludeValueName name] ++
      [tokenText name | (prefix,dot,name) <- zip3 tokens (drop 1 tokens) (drop 2 tokens),
        tokenKind prefix == WordToken,tokenText prefix == "prelude",tokenText dot == ".",
        tokenKind name == WordToken,preludeValueName (tokenText name)]
