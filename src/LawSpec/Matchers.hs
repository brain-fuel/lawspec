-- Matchers: readable predicates for laws, such as xs has same items as ys,
-- t matches regex "...", or v matches Shipped _ _. The parser turns each one
-- into a prelude call or a match (see Parser.matcherSuffix); this module
-- holds the built-in unit that defines the ones over lists, lawspec.matchers,
-- added only to programs that use them, as lawspec.collections is. Its
-- operations are checked LawSpec definitions, so every target runs the same
-- code; the text matchers are runtime helpers, and regexes are checked here
-- at compile time (LawSpec.Regex).
module LawSpec.Matchers
  ( matchersUnit, matchersAlias, matchersSource, matchersTypes, usesMatchers
  , matcherOperation, matcherOperations, regexTypeName
  ) where

import Data.Char (isAlphaNum)
import LawSpec.SourceTokens (Token(..), TokenKind(..), sourceTokens)

matchersUnit :: String
matchersUnit = "lawspec.matchers"

-- The implicit import's alias; prelude.<op> resolves through it.
matchersAlias :: String
matchersAlias = "lawspecMatchers"

-- The unit's types, imported by every source that uses matchers.
matchersTypes :: [String]
matchersTypes = ["Regex"]

regexTypeName :: String
regexTypeName = matchersUnit ++ "::type::Regex"

-- prelude.<op> and the definition implementing it.
matcherOperation :: String -> Maybe String
matcherOperation op = lookup op matcherOperations

matcherOperations :: [(String,String)]
matcherOperations =
  [ ("sameItems", "matchersSameItems"), ("containsAll", "matchersContainsAll")
  , ("isSubsetOf", "matchersIsSubsetOf"), ("matchesRegex", "matchersMatchesRegex") ]

-- Whether a source uses a matcher that needs the unit: same items, contains
-- all of, is subset of, or a regex. A source that declares its own Regex
-- keeps it.
usesMatchers :: String -> Bool
usesMatchers text =
  let code = concat [if tokenKind token `elem` [LiteralToken,PhraseToken,CommentToken]
                    then " " else tokenText token | token <- sourceTokens text]
      tokens = words (map (\c -> if isAlphaNum c || c `elem` ("._" :: String) then c else ' ') code)
      pairs = zip3 tokens (drop 1 tokens) (drop 2 tokens)
      declared = or [keyword `elem` ["type", "wrapper"] && name == "Regex" | (keyword, name) <- zip tokens (drop 1 tokens)]
  in not declared && (or [ (a, b) == ("same", "items") || (a, b, c) == ("contains", "all", "of") || (a, b, c) == ("is", "subset", "of")
                         | (a, b, c) <- pairs ] || any (`elem` tokens)
                           (["regex", "Regex"] ++ ["prelude." ++ operation | (operation,_) <- matcherOperations]))

matchersSource :: String
matchersSource = unlines
  [ "unit lawspec.matchers"
  , ""
  , "type Regex is a record{  pattern :: Text} end type"
  , ""
  , "-- ys without the first item equal to x, or Nothing when there is none."
  , "function matchersRemoveFirst (x :: a) (ys :: List a) -> Maybe (List a) requires Eq a is"
  , "  first matching case of ys :"
  , "  when Nil then Nothing"
  , "  when Cons h t then if h = x then Just t else"
  , "      (first matching case of matchersRemoveFirst x t :"
  , "       when Nothing then Nothing"
  , "       when Just rest then Just (Cons h rest)"
  , "       end case) end if"
  , "  end case"
  , "end function"
  , ""
  , "-- The same items, each as many times, in any order."
  , "function matchersSameItems (xs :: List a) (ys :: List a) -> Bool requires Eq a is"
  , "  first matching case of xs :"
  , "  when Nil then (first matching case of ys : when Nil then true when Cons h t then false end case)"
  , "  when Cons h t then first matching case of matchersRemoveFirst h ys :"
  , "    when Nothing then false"
  , "    when Just rest then matchersSameItems t rest"
  , "    end case"
  , "  end case"
  , "end function"
  , ""
  , "function matchersHas (xs :: List a) (x :: a) -> Bool requires Eq a is"
  , "  first matching case of xs :"
  , "  when Nil then false"
  , "  when Cons h t then if h = x then true else matchersHas t x end if"
  , "  end case"
  , "end function"
  , ""
  , "-- Every item of ys is among xs."
  , "function matchersContainsAll (xs :: List a) (ys :: List a) -> Bool requires Eq a is"
  , "  first matching case of ys :"
  , "  when Nil then true"
  , "  when Cons h t then if matchersHas xs h then matchersContainsAll xs t else false end if"
  , "  end case"
  , "end function"
  , ""
  , "function matchersIsSubsetOf (xs :: List a) (ys :: List a) -> Bool requires Eq a is"
  , "  matchersContainsAll ys xs"
  , "end function"
  , ""
  , "function matchersMatchesRegex (t :: Text) (r :: Regex) -> Bool is"
  , "  first matching case of r : when Regex record{ pattern = p} then prelude.regexMatches p t end case"
  , "end function"
  , "end unit" ]
