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
  , matcherOperation, regexTypeName
  ) where

import Data.Char (isAlphaNum)
import Data.List (isPrefixOf, tails)

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
matcherOperation op = lookup op
  [ ("sameItems", "matchersSameItems"), ("containsAll", "matchersContainsAll")
  , ("isSubsetOf", "matchersIsSubsetOf"), ("matchesRegex", "matchersMatchesRegex") ]

-- Whether a source uses a matcher that needs the unit: same items, contains
-- all of, is subset of, or a regex. A source that declares its own Regex
-- keeps it.
usesMatchers :: String -> Bool
usesMatchers text =
  let tokens = words (map (\c -> if isAlphaNum c || c `elem` ("._" :: String) then c else ' ') (stripComments (dropStrings text)))
      pairs = zip3 tokens (drop 1 tokens) (drop 2 tokens)
      declared = or [keyword `elem` ["type", "wrapper"] && name == "Regex" | (keyword, name) <- zip tokens (drop 1 tokens)]
  in not declared && (or [ (a, b) == ("same", "items") || (a, b, c) == ("contains", "all", "of") || (a, b, c) == ("is", "subset", "of")
                         | (a, b, c) <- pairs ] || any (`elem` tokens) ["regex", "Regex"])
  where
    stripComments = unlines . map takeComment . lines
    takeComment line = case [i | (i, rest) <- zip [0 :: Int ..] (tails line), "--" `isPrefixOf` rest] of
      i : _ -> take i line
      [] -> line
    -- Text in quotes is not code, but a regex literal's keyword is outside them.
    dropStrings s = case s of
      '"' : rest -> ' ' : dropStrings (skip rest)
      c : rest -> c : dropStrings rest
      [] -> []
    skip s = case s of
      '\\' : _ : rest -> skip rest
      '"' : rest -> rest
      _ : rest -> skip rest
      [] -> []

matchersSource :: String
matchersSource = unlines
  [ "unit " ++ matchersUnit
  , ""
  -- A regex in the portable dialect (LawSpec.Regex). Its values come from
  -- regex literals, which the compiler checks.
  , "type Regex is Regex pattern :: Text end"
  , ""
  , "-- ys without the first item equal to x, or Nothing when there is none."
  , "definition matchersRemoveFirst (x :: a) (ys :: List a) :: Maybe (List a) requires Eq a is"
  , "  match ys with"
  , "  | Nil -> Nothing"
  , "  | Cons h t -> if h == x then Just t else"
  , "      (match matchersRemoveFirst x t with"
  , "       | Nothing -> Nothing"
  , "       | Just rest -> Just (Cons h rest)"
  , "       end)"
  , "  end"
  , "end"
  , ""
  , "-- The same items, each as many times, in any order."
  , "definition matchersSameItems (xs :: List a) (ys :: List a) :: Bool requires Eq a is"
  , "  match xs with"
  , "  | Nil -> (match ys with | Nil -> true | Cons h t -> false end)"
  , "  | Cons h t -> match matchersRemoveFirst h ys with"
  , "    | Nothing -> false"
  , "    | Just rest -> matchersSameItems t rest"
  , "    end"
  , "  end"
  , "end"
  , ""
  , "definition matchersHas (xs :: List a) (x :: a) :: Bool requires Eq a is"
  , "  match xs with"
  , "  | Nil -> false"
  , "  | Cons h t -> if h == x then true else matchersHas t x"
  , "  end"
  , "end"
  , ""
  , "-- Every item of ys is among xs."
  , "definition matchersContainsAll (xs :: List a) (ys :: List a) :: Bool requires Eq a is"
  , "  match ys with"
  , "  | Nil -> true"
  , "  | Cons h t -> if matchersHas xs h then matchersContainsAll xs t else false"
  , "  end"
  , "end"
  , ""
  , "definition matchersIsSubsetOf (xs :: List a) (ys :: List a) :: Bool requires Eq a is"
  , "  matchersContainsAll ys xs"
  , "end"
  , ""
  , "definition matchersMatchesRegex (t :: Text) (r :: Regex) :: Bool is"
  , "  match r with | Regex p -> prelude.regexMatches p t end"
  , "end"
  ]
