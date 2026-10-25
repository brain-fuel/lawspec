-- | Conservative dependency slices for presentation-bearing surface memos.
-- These run before checked Core identity exists. They must retain spellings
-- and spans, while excluding unrelated signatures and nominal types. They
-- never establish semantic identity or bypass mandatory admission.
module LawSpec.SurfaceContext (contextFor, mentionedNames) where

import Data.Aeson (ToJSON(..), Value(..))
import qualified Data.Aeson.Key as Key
import qualified Data.Aeson.KeyMap as KeyMap
import qualified Data.Foldable as F
import qualified Data.Map.Strict as M
import qualified Data.Set as S
import qualified Data.Text as T
import qualified LawSpec.Core as C
import qualified LawSpec.Core.Identity as Identity
import qualified LawSpec.Dependencies as D
import qualified LawSpec.Model as Surface
import LawSpec.SourceContext (SourceContext(..))

-- | Inspect the structured AST, never its printed or generated source.
-- Strings in documentary fields can conservatively add an edge; they cannot
-- remove a real edge. Existing source AST JSON instances retain names in all
-- syntax positions, including dependent annotations and constructor literals.
mentionedNames :: ToJSON a => a -> S.Set String
mentionedNames = S.fromList . map shortName . strings . toJSON
  where
    strings (String s) = [T.unpack s]
    strings (Array xs) = concatMap strings (F.toList xs)
    strings (Object fields) = concat
      [[Key.toString key] ++ strings value | (key,value) <- KeyMap.toList fields]
    strings _ = []

shortName :: String -> String
shortName = reverse . takeWhile (`notElem` (":." :: String)) . reverse

-- | Close the names mentioned by the surface value through signatures and
-- the checked data graph. Structural records remain a conservative common
-- input until surface records have been assigned their checked identities.
-- The returned context is used only in a memo key; elaboration still receives
-- the complete validated environment and preserves all source presentation.
contextFor :: ToJSON a => [(String, Surface.Type)] -> [C.DataDeclaration]
  -> SourceContext -> a -> ([(String, Surface.Type)], [C.DataDeclaration], SourceContext)
contextFor signatures declarations (SourceContext source) =
  let graph = D.dependencyGraph declarations []
      grow names =
        let functions = [(name,ty) | (name,ty) <- signatures, S.member (shortName name) names]
            roots = [D.TypeNode (C.dataId d) | d <- declarations,
              C.dataStructural d /= Nothing || any (`S.member` names)
                (map shortName (C.idText (C.dataId d) : C.dataName d :
                  [C.idText (C.constructorId c) | c <- C.dataConstructors d] ++
                  [C.constructorName c | c <- C.dataConstructors d]))]
            reached = D.closure graph roots
            selected = [d | d <- declarations, S.member (D.TypeNode (C.dataId d)) reached]
            more = S.unions (names : map (mentionedNames . snd) functions ++
              [S.fromList (map shortName (Identity.references d)) | d <- selected])
            keys = S.fromList (map C.dataId selected ++ [C.constructorId c | d <- selected, c <- C.dataConstructors d])
        in if more == names then (functions, selected, SourceContext (M.restrictKeys source keys)) else grow more
  in \value -> grow (mentionedNames value)
