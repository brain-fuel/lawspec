-- | Record type scopes must survive the surface transformations before their
-- restrictions can become canonical, checked constructor contracts.
-- ref:DEC-typed-core-boundary ref:DEC-readable-notation
module SourceRecordScopeSpec (test_recordTypeScopesPreserveDependencies) where

import Control.Monad (forM_)
import Data.Binary (decode,encode)
import Data.List (nub,sort)
import qualified Data.Map.Strict as M
import Test.Hspec
import qualified LawSpec.Eval as Eval
import qualified LawSpec.Imports as Imports
import qualified LawSpec.Model as S
import qualified LawSpec.Parser as Parser
import LawSpec.Persist ()
import qualified LawSpec.Refinement as R
import LawSpec.Scalar (Scalar(..))

integer :: S.Type
integer = S.Named "Integer"
field :: String -> S.Type -> S.RecordField
field name = S.RecordField name name
above :: S.Expr -> S.Type
above lower = S.Refined "value" integer (Just (S.Binary ">" (S.Var "value") lower))
shape :: S.Type
shape = S.Record [field "width" integer,
  field "height" (above (S.Binary "+" (S.Var "width") (S.Var "floor")))]
free :: S.Type -> [String]
free = sort . nub . S.typeValueVars

-- This oracle evaluates the actual substituted predicates. A field binding's
-- spelling may change, but it still receives its own labelled stored value.
accepts :: S.Type -> [(String,Integer)] -> [(String,Integer)] -> Either String Bool
accepts (S.Record fields) values outer = and <$> sequence
  [Eval.evaluateBool 64 environment predicate
  | f <- fields, predicate <- S.typePredicates (S.Var (S.recordFieldBinding f)) (S.recordFieldType f)]
  where
    environment = [(S.recordFieldBinding f,SInteger "Integer" value)
      | f <- fields, Just value <- [lookup (S.recordFieldLabel f) values]] ++
      [(name,SInteger "Integer" value) | (name,value) <- outer]
accepts _ _ _ = Left "record type expected"

parsed :: String -> S.Unit
parsed text = either (error . show) id (Parser.parseSource (S.Source "scope.lawspec" text))

test_recordTypeScopesPreserveDependencies :: Spec
test_recordTypeScopesPreserveDependencies = describe "source record type scopes" $ do
  it "retains intrinsic restrictions when erasing an enclosing refinement" $ do
    S.baseType (S.Refined "picture" shape (Just (S.BoolLit True))) `shouldBe` shape
    S.baseType (S.Applied "List" shape) `shouldBe` S.Applied "List" shape
    shape `shouldNotBe` S.Record [field "width" integer,field "height" integer]
  it "treats own and earlier field binders as local dependencies" $ do
    free shape `shouldBe` ["floor"]
    free (S.Record [field "width" (above (S.Var "width"))]) `shouldBe` []
    free (S.Record [field "first" (above (S.Var "later")),field "later" integer])
      `shouldBe` ["later"]
  it "does not turn value dependencies into type variable names" $ do
    let named = S.Application "Pair" [S.Named "Floor",S.Variable "width"]
    S.replaceTypeValueVars [("width",S.Number 3),("Floor",S.Number 4)] named `shouldBe` named
  it "substitutes an outer bound without capturing it as a record field" $ do
    let changed = S.replaceTypeValueVars [("floor",S.Var "width")] shape
    free changed `shouldBe` ["width"]
    forM_ [(-3,2), (50,100), (105,100), (0,-2)] $ \(height,lower) ->
      accepts changed [("width",2),("height",height)] [("width",lower)]
        `shouldBe` accepts shape [("width",2),("height",height)] [("floor",lower)]
    case changed of
      S.Record fields -> do
        map S.recordFieldLabel fields `shouldBe` ["width","height"]
        S.recordFieldBinding (head fields) `shouldNotBe` "width"
      _ -> expectationFailure "lost record type"
  it "shadows an outer substitution at the current field and subsequent fields" $ do
    let changed = S.replaceTypeValueVars [("width",S.Number 99),("floor",S.Number 0)] shape
    free changed `shouldBe` []
    accepts changed [("width",2),("height",3)] [] `shouldBe` Right True
    accepts changed [("width",2),("height",1)] [] `shouldBe` Right False
  it "keeps forward references free even when a later field has that label" $ do
    let original = S.Record [field "first" (above (S.Var "later")),field "later" integer]
        changed = S.replaceTypeValueVars [("later",S.Number 7)] original
    accepts changed [("first",5),("later",1)] [] `shouldBe` Right False
    accepts changed [("first",8),("later",100)] [] `shouldBe` Right True
  it "keeps nested records' same-named fields in separate scopes" $ do
    let nested = S.Record [field "width" integer,field "dimensions" shape]
        changed = S.replaceTypeValueVars [("floor",S.Var "width")] nested
    free changed `shouldBe` ["width"]
    case changed of
      S.Record [_,inner] -> do
        accepts (S.recordFieldType inner) [("width",2),("height",50)] [("width",100)] `shouldBe` Right False
        accepts (S.recordFieldType inner) [("width",2),("height",105)] [("width",100)] `shouldBe` Right True
      _ -> expectationFailure "lost nested record type"
  it "renames a record binder before substituting a type with free value dependencies" $ do
    let generic = S.Record [field "width" integer,field "payload" (S.Variable "a")]
        changed = R.substituteType (M.singleton "a" (above (S.Var "width"))) M.empty generic
    free changed `shouldBe` ["width"]
    accepts changed [("width",2),("payload",50)] [("width",100)] `shouldBe` Right False
    accepts changed [("width",2),("payload",105)] [("width",100)] `shouldBe` Right True
  it "keeps type and value substitutions distinct at a shadowing field" $ do
    let generic = S.Record [field "width" integer,field "payload" (S.Variable "a")]
        changed = R.substituteType (M.singleton "a" (above (S.Var "width")))
          (M.singleton "width" (S.Number 0)) generic
    free changed `shouldBe` ["width"]
    accepts changed [("width",2),("payload",50)] [("width",100)] `shouldBe` Right False
  it "avoids existing fresh-name candidates and preserves source origins" $ do
    let range = S.Span (S.Location "record.lawspec" 4 9) (S.Location "record.lawspec" 4 30)
        original = S.Record [field "width" integer,field "height"
          (S.Refined "value" integer (Just (S.Located range (S.Binary ">" (S.Var "floor") (S.Var "_record_width_0")))))]
        changed = S.replaceTypeValueVars [("floor",S.Var "width")] original
    case changed of
      S.Record [first,second] -> do
        S.recordFieldBinding first `shouldNotBe` "_record_width_0"
        S.typePredicates (S.Var "height") (S.recordFieldType second) `shouldBe`
          [S.Located range (S.Binary ">" (S.Var "width") (S.Var "_record_width_0"))]
      _ -> expectationFailure "lost field or source origin"
  it "substitutes dependencies inside expression annotations" $ do
    let expression = S.Annotate (S.Var "picture") shape
        changed = S.replaceExprVars [("floor",S.Var "width")] expression
    sort (S.exprVars changed) `shouldBe` ["picture","width"]
    case changed of
      S.Annotate _ ty -> accepts ty [("width",2),("height",50)] [("width",100)] `shouldBe` Right False
      _ -> expectationFailure "lost annotation"
  it "includes annotation dependencies when avoiding capture by a match binder" $ do
    let expression = S.MatchExpr (S.Var "selected") [S.MatchBranch S.letTag ["width"]
          (S.Annotate (S.Number 0) (above (S.Var "floor")))]
        changed = S.replaceExprVars [("floor",S.Var "width")] expression
    sort (S.exprVars changed) `shouldBe` ["selected","width"]
    case changed of
      S.MatchExpr _ [S.MatchBranch _ [binder] _] -> binder `shouldNotBe` "width"
      _ -> expectationFailure "lost match binder"
  it "substitutes representation-bound type dependencies too" $ do
    let original = S.TypeBound "max" (S.RefinementApp "BoundedBy" [S.ValueArgument (S.Var "limit")])
    S.replaceExprVars [("limit",S.Number 7)] original `shouldBe`
      S.TypeBound "max" (S.RefinementApp "BoundedBy" [S.ValueArgument (S.Number 7)])
    S.exprVars original `shouldBe` ["limit"]
  it "avoids capturing replacement type dependencies inside refinement annotations" $ do
    let original = S.Refined "width" integer (Just
          (S.Binary "==" (S.Annotate (S.Number 0) (S.Variable "a")) (S.Number 0)))
        changed = R.substituteType (M.singleton "a" (above (S.Var "width"))) M.empty original
    free changed `shouldBe` ["width"]
    case changed of
      S.Refined binder _ _ -> binder `shouldNotBe` "width"
      _ -> expectationFailure "lost refinement binder"
  it "substitutes annotation dependencies simultaneously rather than transitively" $ do
    let annotation = S.RefinementApp "Above" [S.ValueArgument (S.Var "floor")]
        original = S.Refined "value" integer (Just (S.Annotate (S.Var "floor") annotation))
        changed = R.substituteType M.empty
          (M.fromList [("floor",S.Var "width"),("width",S.Number 0)]) original
    changed `shouldBe` S.Refined "value" integer (Just (S.Annotate (S.Var "width")
      (S.RefinementApp "Above" [S.ValueArgument (S.Var "width")])))
  it "does not re-substitute dependencies introduced by replacement types" $ do
    let original = S.CheckedType [S.Annotate (S.Number 0) (S.Variable "a")] integer
        changed = R.substituteType (M.singleton "a" (above (S.Var "width")))
          (M.singleton "width" (S.Number 0)) original
    changed `shouldBe` S.CheckedType [S.Annotate (S.Number 0) (above (S.Var "width"))] integer
  it "avoids expression binders when introducing type dependencies" $ do
    let expression = S.AllElementsExpr (S.Var "xs") "width"
          (S.Annotate (S.Number 0) (S.Variable "a"))
        original = S.CheckedType [expression] integer
        changed = R.substituteType (M.singleton "a" (above (S.Var "width"))) M.empty original
    free changed `shouldBe` ["width","xs"]
    case changed of
      S.CheckedType [S.AllElementsExpr _ binder _] _ -> binder `shouldNotBe` "width"
      _ -> expectationFailure "lost element predicate binder"
  it "traverses nested field types, predicates and capability requirements" $ do
    let original = S.Record [field "item" (S.Qualified [S.Capability "Eq" (S.Variable "a")]
          (S.Refined "value" (S.Variable "a") (Just (S.Var "predicate"))))]
        changed = S.mapType (\ty -> if ty == S.Variable "a" then integer else ty)
          (S.replaceExprVars [("predicate",S.BoolLit True)]) original
    S.typeConstraints changed `shouldBe` [S.Capability "Eq" integer]
    changed `shouldBe` S.Record [field "item" (S.Qualified [S.Capability "Eq" integer]
      (S.Refined "value" integer (Just (S.BoolLit True))))]
  it "expands aliases inside records while preserving their restrictions" $ do
    let positive = S.Refinement "Positive" [] [] (above (S.Number 0))
        original = S.Record [field "count" (S.RefinementApp "Positive" [])]
    case R.expandType M.empty (M.singleton "Positive" positive) [] M.empty M.empty original of
      Left message -> expectationFailure message
      Right changed -> do
        R.hasValueRefinements changed `shouldBe` True
        accepts changed [("count",0)] [] `shouldBe` Right False
        accepts changed [("count",1)] [] `shouldBe` Right True
  it "round-trips dependent records through the persistent surface cache" $ do
    let changed = R.substituteType M.empty (M.singleton "floor" (S.Var "width")) shape
    (decode (encode (S.Arrow shape changed)) :: S.Type) `shouldBe` S.Arrow shape changed
  it "resolves imported types and refinements without importing field bindings" $ do
    let provider = parsed (unlines [ "unit measures"
                                    ++ "\n", ""
                                   , "type Token is one of Token end type\n"
                                   , "function threshold (input :: Integer) -> Integer is input end function\n"
                                   , "function width (input :: Integer) -> Integer is input end function\n"
                                   , "refinement Above (lower :: Integer) is (v :: Integer where v > lower) end refinement"
                                   , "\nend unit" ])
        consumer = parsed "unit drawing\n\nf :: Unit -> Unit\nend unit\n"
        ty = S.Record [field "object" (S.Named "Token"),field "width" integer,
          field "height" (above (S.Binary "+" (S.Var "width") (S.Apply (S.Var "threshold") (S.Number 10)))),
          field "larger" (S.RefinementApp "Above" [S.ValueArgument (S.Var "width")]),
          field "constrained" (S.Qualified [S.Capability "Eq"
            (S.RefinementApp "Above" [S.ValueArgument (S.Var "width")])] integer)]
        imports = [S.Import "measures" "measures" ["Token","Above","threshold","width"]
          (S.Span (S.Location "scope.lawspec" 1 1) (S.Location "scope.lawspec" 1 50))]
        units = [(provider,[]),(consumer{S.functions=[("f",ty)]},imports)]
    case Imports.resolveImports (\_ _ -> Nothing) units of
      Left diagnostics -> expectationFailure (show diagnostics)
      Right [_,resolved] -> case lookup "f" (S.functions resolved) of
        Just (S.Record [object,_,height,larger,constrained]) -> do
          S.recordFieldType object `shouldBe` S.Named "measures::type::Token"
          free (S.recordFieldType height) `shouldMatchList` ["width",Imports.importedDefinitionName "measures" "threshold"]
          S.recordFieldType larger `shouldBe` S.RefinementApp "measures::Above" [S.ValueArgument (S.Var "width")]
          S.typeConstraints (S.recordFieldType constrained) `shouldBe` [S.Capability "Eq"
            (S.RefinementApp "measures::Above" [S.ValueArgument (S.Var "width")])]
        _ -> expectationFailure "lost resolved record fields"
      Right _ -> expectationFailure "unexpected resolved units"
  it "leaves forward field dependencies free for declaration validation" $ do
    let unit = parsed "unit drawing\n\nf :: Unit -> Unit\nend unit\n"
        ty = S.Record [field "first" (above (S.Var "later")),field "later" integer]
    case Imports.resolveImports (\_ _ -> Nothing) [(unit{S.functions=[("f",ty)]},[])] of
      Left diagnostics -> expectationFailure (show diagnostics)
      Right [resolved] -> fmap free (lookup "f" (S.functions resolved)) `shouldBe` Just ["later"]
      Right _ -> expectationFailure "unexpected resolved units"
