module HaskellSchemaCheck (checkSchemas) where

import Control.Monad (forM_, unless)
import Data.List (isInfixOf)
import qualified LawSpecSchema as S
import qualified LawSpecDataSchema as Data
import qualified LawSpecRuntime as LS

assert :: String -> Bool -> IO ()
assert label condition = unless condition (error label)

reject :: String -> Either String a -> IO ()
reject fragment result = case result of
  Left message -> assert ("missing context: " ++ message) (fragment `isInfixOf` message)
  Right _ -> error ("expected rejection: " ++ fragment)

checkSchemas :: IO ()
checkSchemas = do
  let schema = either error id Data.schema
      named name = S.Named name []
      tree ty = S.Named "Tree" [named ty]
  forM_ [32, 64] $ \bits -> do
    let make ty tag fields = either error id (S.construct schema ty bits tag fields)
        leaf = make (tree "Int8") "ctor::Leaf" [LS.SInteger "Int8" 127]
        branch = make (tree "Int8") "ctor::Branch" [LS.SList [leaf]]
        equal ty = S.equal schema ty bits
    assert "recursive schema equality" (equal (tree "Int8") branch branch == Right True)
    assert "constructor identity" (equal (tree "Int8") branch leaf == Right False)
    reject "ctor::Leaf.value" (S.construct schema (tree "Int8") bits "ctor::Leaf" [LS.SInteger "Int8" 128])
    reject "ctor::Leaf.value" (S.construct schema (tree "Int8") bits "ctor::Leaf" [LS.SBool True])
    reject "ctor::Leaf.value" (S.equal schema (tree "Int8") bits branch (LS.SData "ctor::Leaf" [LS.SBool True]))
    reject "ctor::Leaf.value" (S.match schema (tree "Int8") bits (LS.SData "ctor::Leaf" [LS.SBool True])
      [("ctor::Leaf", const True)])
    reject "field count" (S.construct schema (tree "Int8") bits "ctor::Leaf" [])
    reject "unknown constructor" (S.construct schema (tree "Int8") bits "ctor::Pair" [])
    reject "unknown constructor" (S.construct schema (S.Named "Empty" [named "Bool"]) bits "anything" [])
    reject "Bool" (S.validate schema (named "Bool") bits (LS.SData "Bool::Fake" []))
    reject "List[0]" (S.validate schema (S.Named "List" [tree "Int8"]) bits (LS.SList [LS.SBool True]))
    let nan = make (tree "Float64") "ctor::Leaf" [LS.floatScalar "Float64" (0/0)]
        positive = make (tree "Float64") "ctor::Leaf" [LS.floatScalar "Float64" 0]
        negative = make (tree "Float64") "ctor::Leaf" [LS.floatScalar "Float64" (-0)]
    assert "IEEE NaN" (equal (tree "Float64") nan nan == Right False)
    assert "signed zero" (equal (tree "Float64") positive negative == Right True)
    let symbol identity description = make (tree "Symbol") "ctor::Leaf" [LS.SSymbol identity description]
    assert "Symbol descriptions are not identities"
      (equal (tree "Symbol") (symbol "a" "same") (symbol "b" "same") == Right False)
    assert "Symbol identity survives description differences"
      (equal (tree "Symbol") (symbol "a" "first") (symbol "a" "second") == Right True)
    forM_ [("CodeUnit16", LS.SCharacter "CodeUnit16" 0xD800),
           ("CodePoint", LS.SCharacter "CodePoint" 0xDFFF),
           ("Utf16Text", LS.SSequence "Utf16Text" [0xD800,0,0xDC00]),
           ("CodePointText", LS.SSequence "CodePointText" [0xD800,0x1F642]),
           ("Bytes", LS.SSequence "Bytes" [0,128,255]),
           ("UInt64", LS.SInteger "UInt64" 18446744073709551615)] $ \(name, value) -> do
      let result = make (tree name) "ctor::Leaf" [value]
      assert "raw scalar preservation" (result == LS.SData "ctor::Leaf" [value])
    reject "ctor::Leaf.value" (S.construct schema (tree "Text") bits "ctor::Leaf" [LS.SSequence "Text" [0xD800]])
    let nested = S.Named "Nullable" [S.Named "Optional" [tree "Int8"]]
        absent = LS.SPresent "Nullable" Nothing
        present = LS.SPresent "Nullable" (Just (LS.SPresent "Optional" Nothing))
    assert "nested presence" (equal nested absent present == Right False)
    let listType = S.Named "List" [tree "Int8"]
        nil = make listType "List::Nil" []
        cons = make listType "List::Cons" [leaf, nil]
    assert "custom data inside lists" (cons == LS.SList [leaf])
    assert "unselected branches stay lazy"
      (S.match schema (tree "Int8") bits leaf
        [("ctor::Leaf", const True), ("ctor::Branch", error "unselected branch")] == Right True)
    reject "missing checked match" (S.match schema (tree "Int8") bits leaf [] :: Either String ())
  reject "machineBits" (S.validate schema (named "Bool") 16 (LS.SBool True))
  reject "wrong arity" (S.checkType schema 0 (named "Tree"))
  reject "duplicate" (S.create [S.Definition "List" 0 []] [])
  reject "unbound" (S.create [S.Definition "Bad" 0
    [S.Constructor "Bad::Make" [S.Field "value" (S.Parameter 0)]]] [])
  reject "unknown type" (S.create [S.Definition "Bad" 0
    [S.Constructor "Bad::Make" [S.Field "value" (named "NotAType")]]] [])
  putStrLn "Haskell schema checks passed"
