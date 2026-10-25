-- | Draw helper sharing preserves lexical capture and lazy choice structure.
-- ref:DEC-planned-generation ref:DEC-native-property-frameworks
module DrawSharingSpec (test_drawHelpersPreserveCapturedScope) where

import Test.Hspec
import qualified LawSpec.Core as C
import LawSpec.Scalar (Scalar(..))
import LawSpec.Testing
import LawSpec.Testing.Draws

integer :: C.Type
integer = C.scalarType "Int64"

binder :: String -> C.Binder
binder name = C.Binder (C.Id name) name integer

local :: C.Binder -> C.Expr
local b = C.Expr integer (C.Local (C.binderId b)) (C.GeneratedFrom (C.Id "draw-sharing"))

one :: C.Draw
one = C.DrawOneOf integer [C.Expr integer (C.Constant (SInteger "Int64" 1)) (C.GeneratedFrom (C.Id "draw-sharing"))]

requirement :: GeneratorRequirement
requirement = GeneratorRequirement (binder "input") [] [] [] [] Nothing

planned :: [C.Binder] -> C.Draw -> DrawPlan
planned scope draw = either error id (planDraw requirement scope draw)

test_drawHelpersPreserveCapturedScope :: Spec
test_drawHelpersPreserveCapturedScope = describe "shared strategy draw helpers" $ do
  it "shares alpha-renamed bodies while passing each branch's own free value" $ do
    let a = binder "left"; b = binder "right"; x = binder "x"; y = binder "y"
        branch bound outer = C.DrawBind bound one (C.DrawOneOf integer
          [C.Expr integer (C.Binary C.Add (C.Numeric integer) (local bound) (local outer)) (C.GeneratedFrom (C.Id "draw-sharing"))])
        plan = planned [a,b] (C.DrawFrequency [(1,branch x a),(1,branch y b)])
    length (drawNodes plan) `shouldBe` 4
    case drawStep (last (drawNodes plan)) of
      FrequencyDraw [(_,left),(_,right)] -> do
        drawCallee left `shouldBe` drawCallee right
        drawArguments left `shouldBe` [C.binderId a]
        drawArguments right `shouldBe` [C.binderId b]
      other -> expectationFailure (show other)
  it "orders helpers before their callers without sampling a branch" $ do
    let x = binder "candidate"
        condition = C.Expr (C.scalarType "Bool") (C.Binary C.Equal (C.Structural integer) (local x) (local x)) (C.GeneratedFrom (C.Id "draw-sharing"))
        plan = planned [] (C.DrawFrequency [(1,C.DrawSuchThat one x condition 4),(2,one)])
        children step = case step of
          FrequencyDraw xs -> map snd xs
          FilterDraw child _ _ _ -> [child]
          BindDraw _ a b -> [a,b]
          _ -> []
    and [drawCallee child < drawNumber node | node <- drawNodes plan, child <- children (drawStep node)] `shouldBe` True
    length [() | node <- drawNodes plan, OneOfDraw _ _ <- [drawStep node]] `shouldBe` 1
  it "keeps distinct discard limits and distinct literal values" $ do
    let x = binder "x"
        condition = C.Expr (C.scalarType "Bool") (C.Binary C.Equal (C.Structural integer) (local x) (local x)) (C.GeneratedFrom (C.Id "draw-sharing"))
        plan = planned [] (C.DrawFrequency [(1,C.DrawSuchThat one x condition 4),(1,C.DrawSuchThat one x condition 5)])
    [limit | node <- drawNodes plan, FilterDraw _ _ _ limit <- [drawStep node]] `shouldBe` [4,5]
  it "captures directed Any bounds and earlier input hints, excluding its own binder" $ do
    let earlier = binder "earlier"
        req = requirement { generatorBounds = [(C.Greater,local earlier)], generatorHints = [local earlier] }
        plan = either error id (planDraw req [earlier] (C.DrawAny integer Nothing))
    map C.binderId (drawCaptures (head (drawNodes plan))) `shouldBe` [C.binderId earlier]
  it "keeps free type parameters distinct while sharing value binders" $ do
    let plan = planned [] (C.DrawFrequency
          [(1,C.DrawAny (C.TypeVariable (C.Id "firstType")) Nothing),
           (1,C.DrawAny (C.TypeVariable (C.Id "secondType")) Nothing)])
    length [() | node <- drawNodes plan, AnyDraw _ _ <- [drawStep node]] `shouldBe` 2
  it "rejects an undeclared capture instead of inventing a native variable" $ do
    planDraw requirement [] (C.DrawOneOf integer [local (binder "missing")])
      `shouldBe` Left "strategy draw has an unbound capture: missing"
