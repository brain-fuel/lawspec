-- | Display names for anonymous records. A structural record's identity is
-- the digest of its shape (Core's RecordIdentity), and that stays its
-- identity, so Core fingerprints never change. Emitters show a name from the
-- first place the record is used, in declaration order: a sum case's payload
-- is <Constructor>Details, a field's record is <Type><Field>, a function's
-- parameter or result is <Function><Parameter> or <Function>Result. Otherwise
-- the field names joined name it, and a short digest is the last resort,
-- lengthened only on a collision. ref:DEC-record-display-names
module LawSpec.RecordNames (RecordContext(..), recordDisplayNames, recordDisplayNamesWith, isStructuralRecord) where

import Data.Char (toUpper)
import Data.List (stripPrefix)
import qualified Data.Map.Strict as M
import Data.Maybe (isJust)
import qualified Data.Set as S
import qualified LawSpec.Core as C
import LawSpec.Naming (nameWords, cased, Casing(..))

-- | Where a record is used outside the data declarations: a function's
-- parameters and result, by name.
data RecordContext = FunctionContext String [(String, C.Type)] C.Type

isStructuralRecord :: C.DataDeclaration -> Bool
isStructuralRecord d = isJust (C.dataStructural d)

-- | Display names from the data declarations alone.
recordDisplayNames :: [C.DataDeclaration] -> M.Map C.Id String
recordDisplayNames = recordDisplayNamesWith []

-- | Display names, also from functions' signatures.
recordDisplayNamesWith :: [RecordContext] -> [C.DataDeclaration] -> M.Map C.Id String
recordDisplayNamesWith contexts declarations = assign M.empty taken0 records
  where
    records = [d | d <- declarations, isStructuralRecord d]
    taken0 = S.fromList [C.dataName d | d <- declarations, not (isStructuralRecord d)]
    byId = M.fromList [(C.dataId d, d) | d <- records]
    -- Every place a record is named from, in declaration order.
    uses = concat
      [ [ (C.Id r, pascal (C.constructorName c) ++ suffix)
        | c <- C.dataConstructors d, let suffix = if length (C.constructorFields c) == 1 then "Details" else ""
        , f <- C.constructorFields c, r <- recordsIn (C.binderType f)
        , not (isStructuralRecord d) ] ++
        [ (C.Id r, pascal (C.dataName d) ++ pascal (C.binderName f))
        | not (isStructuralRecord d), length (C.dataConstructors d) == 1
        , c <- C.dataConstructors d, f <- C.constructorFields c, r <- recordsIn (C.binderType f) ]
      | d <- declarations ] ++
      concat [ [ (C.Id r, pascal function ++ pascal parameter) | (parameter, ty) <- parameters, r <- recordsIn ty ] ++
               [ (C.Id r, pascal function ++ "Result") | r <- recordsIn result ]
             | FunctionContext function parameters result <- contexts ]
    recordsIn ty = case ty of
      C.Constructor n args -> [n | M.member (C.Id n) byId] ++ concat [recordsIn t | C.TypeArgument t <- args]
      C.Arrow a b -> recordsIn a ++ recordsIn b
      _ -> []
    candidates d =
      [n | (i, n) <- uses, i == C.dataId d, not (null n)] ++
      [concatMap (pascal . C.binderName) fields' | [c] <- [C.dataConstructors d], let fields' = C.constructorFields c, not (null fields'), length fields' <= 3] ++
      [ "Record_" ++ take n digest | n <- [8, 12 .. length digest] ] ++ ["Record_" ++ digest]
      where digest = maybe (C.dataName d) id (stripPrefix "Record" (C.dataName d))
    assign names _ [] = names
    assign names taken (d : rest) =
      let chosen = case [c | c <- candidates d, c `S.notMember` taken] of
            c : _ -> c
            [] -> C.dataName d
      in assign (M.insert (C.dataId d) chosen names) (S.insert chosen taken) rest
    pascal = cased Pascal . nameWords . capitalised
    capitalised (c : cs) = toUpper c : cs
    capitalised [] = []
