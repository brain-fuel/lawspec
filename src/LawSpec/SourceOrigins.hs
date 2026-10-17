-- | Coordinates for compiler-inserted namespace qualifiers. Original source
-- characters retain their positions; generated characters point to their
-- insertion site. This is source provenance, not another syntax representation.
module LawSpec.SourceOrigins
  ( SourceOriginMap, insertSourceNames, sourceOriginFor, sourceCoordinatesFor, originalLocation ) where

import LawSpec.Common
import qualified Data.IntMap.Strict as IM
import Data.List (find,sortOn)
import Control.Monad (unless)

data SourceOriginMap = SourceOriginMap Source (IM.IntMap Location)

sourceOriginFor :: [SourceOriginMap] -> Source -> Maybe SourceOriginMap
sourceOriginFor origins source = find same origins
  where same (SourceOriginMap prepared _) = prepared==source

-- Parser display columns can count a wide character twice. Public source
-- coordinates count code points, with eight-column tab stops, even when the
-- compiler has inserted no namespace qualifiers.
sourceCoordinatesFor :: [SourceOriginMap] -> Source -> SourceOriginMap
sourceCoordinatesFor origins source = case sourceOriginFor origins source of
  Just coordinates -> coordinates
  Nothing -> SourceOriginMap source (authoredPositions source)

authoredPositions :: Source -> IM.IntMap Location
authoredPositions source = IM.fromDistinctAscList
  (zip [0..] (scanl advance (Location (path source) 1 1) (content source)))
  where
    advance (Location name row col) character =
      let (nextRow,nextCol)=case character of
            '\n' -> (row+1,1)
            '\t' -> (row,col+8-((col-1) `mod` 8))
            _ -> (row,col+1)
      in nextRow `seq` nextCol `seq` Location name nextRow nextCol

originalLocation :: SourceOriginMap -> Int -> Maybe Location
originalLocation (SourceOriginMap _ positions) offset = IM.lookup offset positions

insertSourceNames :: Source -> [(Int,String)] -> Either String (Source,Maybe SourceOriginMap)
insertSourceNames source [] = Right (source,Nothing)
insertSourceNames source insertions = do
  let text=content source
      size=length text
      edits=sortOn fst insertions
  unless (all (\(offset,added)->offset>=0&&offset<=size&&all (`notElem` ['\r','\n']) added) edits)
    (Left "invalid namespace insertion")
  let pieces cursor remaining [] = zip remaining [cursor..]
      pieces cursor remaining ((offset,added):rest) =
        let (retained,after)=splitAt (offset-cursor) remaining
        in zip retained [cursor..]++[(character,offset) | character<-added]++pieces offset after rest
      preparedCharacters=pieces 0 text edits
      prepared=source{content=map fst preparedCharacters}
      authored=authoredPositions source
      offsets=map snd preparedCharacters++[size]
      positions=IM.fromDistinctAscList [(offset,authored IM.! original) | (offset,original)<-zip [0..] offsets]
  pure (prepared,Just (SourceOriginMap prepared positions))
