-- | Names the compiler gives values in source-level definitions it writes
-- itself, before Core: a clause made by `op by f`, a law about an
-- operation's results, a model's start definition.
module LawSpec.SourceNames (operationValueNames) where

import LawSpec.Model
import LawSpec.Naming (Casing(..), cased, nameWords)

-- | The names an operation's values take where the compiler writes them
-- itself (a clause made by `op by f`, a law about the operation's results):
-- the name the signature gives each, or one made from its type and numbered
-- from 1 (int32_1, text_1), as LawSpec.Naming names an unnamed parameter in
-- text about the spec. A name already taken is numbered from 2.
-- ref:DEC-generated-parameter-names
operationValueNames :: [String] -> [Type] -> [String]
operationValueNames taken = go taken []
  where
    go _ _ [] = []
    go used seen (t : rest) =
      let (stem, seen') = case t of
            Refined n _ _ | not (implicit n) -> (n, seen)
            _ -> let hd = headOf t in (hd ++ "_" ++ show (1 + length (filter (== hd) seen)), hd : seen)
          chosen = case [c | c <- stem : [stem ++ "_" ++ show i | i <- [2 :: Int ..]], c `notElem` used] of
            c : _ -> c
            [] -> stem
      in chosen : go (chosen : used) seen' rest
    -- LawSpec.Indexed names an unnamed indexed argument indexed<position>.
    implicit n = case splitAt 7 n of
      ("indexed", digits@(_ : _)) -> all (`elem` ['0' .. '9']) digits
      _ -> False
    headOf t = case t of
      Named n -> snake n
      Applied n _ -> snake n
      Application n _ -> snake n
      Refined _ inner _ -> headOf inner
      Qualified _ inner -> headOf inner
      CheckedType _ inner -> headOf inner
      Arrow _ _ -> "function"
      Record _ -> "record"
      _ -> "value"
    snake n = case cased Snake (nameWords (reverse (takeWhile (`notElem` (".:" :: String)) (reverse n)))) of
      "" -> "value"
      name -> name
