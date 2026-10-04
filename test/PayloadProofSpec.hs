module PayloadProofSpec (spec) where

import Test.Hspec
import Control.Monad (forM_)
import Data.Either (isLeft, isRight)
import Data.List (isInfixOf)
import qualified Data.Map.Strict as M
import LawSpec.Common
import LawSpec.Core
import LawSpec.Core.Expression (operationEvidence)
import LawSpec.Core.Total (validateDefinitionContracts)
import LawSpec.Core.Definitions (prepareDefinitions)
import LawSpec.Core.Eval (validateValueWithContracts)
import LawSpec.Core.Types (makeRegistry)
import qualified LawSpec.Core.PayloadPlan as P
import qualified LawSpec.Core.Totality as T
import LawSpec.Core.Value
import LawSpec.Scalar (Scalar(..))

origin = GeneratedFrom (Id "payload-proof")
int = scalarType "Int8"
bool = scalarType "Bool"
rat = scalarType "Rational"
app name arguments = Constructor name (map TypeArgument arguments)
variable name = TypeVariable (Id name)
bind name ty = Binder (Id name) name ty
local binder = Expr (binderType binder) (Local (binderId binder)) origin
literal n = Expr int (Constant (SInteger "Int8" n)) origin
truth b = Expr bool (Constant (SBool b)) origin
binary op left right =
  let evidence = either error id (operationEvidence op (expressionType left) (expressionType right))
      ty = if isComparison op then bool else case evidence of Numeric t -> t; Structural t -> t
  in Expr ty (Binary op evidence left right) origin
construct ty tag fields = Expr ty (Construct (Id tag) fields) origin
match ty value cases = Expr ty (Match value cases) origin
branch tag binders body = MatchCase (Id tag) binders body
variant owner tag fields = DataConstructor (Id (owner ++ "::" ++ tag)) tag
  [bind (owner ++ "::" ++ tag ++ "::" ++ name) ty | (name,ty) <- fields] [] origin [] []
structure name parameters variants = DataDeclaration (Id name) name (map Id parameters) variants origin Nothing
forallPayload value predicates = Expr bool (AllPayloads value predicates) origin
positive name ty value = let member = bind name ty
  in forallPayload value [(member,binary Greater (local member) (literal 0))]
function name arguments result body = Definition
  (Declaration (Id name) name (foldr Arrow result (map binderType arguments)) origin) arguments body
contract definition result pre post = Contract
  (declarationId (definitionDeclaration definition)) (definitionArguments definition) result pre post []
check dat definitions contracts = validateDefinitionContracts 64 dat definitions contracts

spec :: Spec
spec = describe "recursive payload proof rules" $ do
  let tree = structure "Tree" ["a"]
        [variant "Tree" "Leaf" [("value",variable "a"),("fixed",int)],
         variant "Tree" "Node" [("child",app "Tree" [variable "a"])],
         variant "Tree" "Forest" [("children",app "List" [app "Tree" [variable "a"]])]]
      ty = app "Tree" [int]
      list = app "List" [ty]
      input = bind "input" ty
      result = bind "result" rat
      n = bind "n" int
      fixed = bind "fixed" int
      child = bind "child" ty
      children = bind "children" list
      first = bind "first" ty
      rest = bind "rest" list
      call value = Expr rat (ExternalCall (Id "reciprocal") [value]) origin
      reciprocal denominator = function "reciprocal" [input] rat
        (match rat (local input)
          [branch "Tree::Leaf" [n,fixed] (binary Divide (literal 1) (local denominator)),
           branch "Tree::Node" [child] (call (local child)),
           branch "Tree::Forest" [children] (match rat (local children)
             [branch "List::Nil" [] (Expr rat (Constant (SRational 0 1)) origin),
              branch "List::Cons" [first,rest] (call (local first))])])
      requirement = positive "member" int (local input)
      law f = contract f result [requirement] []
  it "uses recursive leaf guarantees for division and strictly descending calls" $ do
    let f = reciprocal n
    forM_ [32,64] $ \bits ->
      validateDefinitionContracts bits [tree] [f] [law f] `shouldBe` Right ()
    let f = reciprocal n
        declaration = definitionDeclaration f
        program = Program 64 [tree]
          [Unit (Id "proof") [declaration] [law f] [] [f] []]
        leaf value = DataValue ty (Id "Tree::Leaf")
          [ScalarValue (SInteger "Int8" value),ScalarValue (SInteger "Int8" 0)]
        value = DataValue ty (Id "Tree::Forest") [listValue ty
          [DataValue ty (Id "Tree::Node") [leaf 2]]]
    case prepareDefinitions program of
      Left diagnostics -> expectationFailure (show diagnostics)
      Right invoke -> do
        invoke (Id "reciprocal") [value] `shouldBe` Right (ScalarValue (SRational 1 2))
        invoke (Id "reciprocal") [leaf 0] `shouldSatisfy` isLeft
  it "does not transfer a parameter guarantee to fixed fields or absent preconditions" $ do
    let bad = reciprocal fixed
        good = reciprocal n
    check [tree] [bad] [law bad] `shouldSatisfy` isLeft
    check [tree] [good] [] `shouldSatisfy` isLeft
  it "does not borrow payload guarantees from another argument or a disjunction" $ do
    let other = bind "other" ty
        base = reciprocal n
        zero = Expr rat (Constant (SRational 0 1)) origin
        f = function "foreign" [input,other] rat (match rat (local input)
          [branch "Tree::Leaf" [n,fixed] (binary Divide (literal 1) (local n)),
           branch "Tree::Node" [child] zero,branch "Tree::Forest" [children] zero])
        wrong = contract f result [positive "foreignMember" int (local other)] []
        disjunction = Expr bool (ShortCircuit Or requirement (truth True)) origin
    check [tree] [f] [wrong] `shouldSatisfy` isLeft
    check [tree] [base] [contract base result [disjunction] []] `shouldSatisfy` isLeft
    check [tree] [f] [contract f result [Expr bool (Unary Not requirement) origin] []]
      `shouldSatisfy` isLeft
  it "proves constructed and recursively wrapped results without inventing leaf facts" $ do
    let out = bind "out" ty
        post = positive "resultMember" int (local out)
        make value = function "make" [input] ty value
        leaf value = construct ty "Tree::Leaf" [literal value,literal (-128)]
        wrapped = construct ty "Tree::Node" [local input]
    forM_ [leaf 1,wrapped] $ \body ->
      let f = make body in check [tree] [f] [contract f out [requirement] [post]] `shouldBe` Right ()
    let bad = make (leaf 0)
    check [tree] [bad] [contract bad out [requirement] [post]] `shouldSatisfy` isLeft
  it "preserves vacuous truth for empty structures and phantom parameters" $ do
    let unit = bind "unused" (scalarType "Unit")
        empty = construct ty "Tree::Forest" [construct list "List::Nil" []]
        f = function "empty" [unit] ty empty
        out = bind "emptyResult" ty
        noMember = forallPayload (local out) [(bind "impossibleMember" int,truth False)]
    check [tree] [f] [contract f out [] [noMember]] `shouldBe` Right ()
    let phantom = structure "Phantom" ["a"] [variant "Phantom" "Tag" []]
        pt = app "Phantom" [int]
        g = function "phantom" [unit] pt (construct pt "Phantom::Tag" [])
        pr = bind "phantomResult" pt
        partial = binary Greater (binary Divide (literal 1) (literal 0)) (literal 0)
        unusedPredicate = forallPayload (local pr) [(bind "unusedPayload" int,partial)]
    check [phantom] [g] [contract g pr [] [unusedPredicate]] `shouldBe` Right ()
  it "audits partial callbacks when their parameter can be stored" $ do
    let member = bind "partialMember" int
        partial = binary Greater (binary Divide (literal 1) (local member)) (literal 0)
        f = function "predicate" [input] bool (forallPayload (local input) [(member,partial)])
        out = bind "predicateResult" bool
    check [tree] [f] [contract f out [] []] `shouldSatisfy` isLeft
  it "canonicalizes growing recursive type arguments into callee-shaped guarantees" $ do
    let nest = structure "Nest" ["a"]
          [variant "Nest" "Stop" [("value",variable "a")],
           variant "Nest" "Next" [("next",app "Nest" [app "List" [variable "a"]])]]
        source = app "Nest" [int]
        ints = app "List" [int]
        destination = app "Nest" [ints]
        x = bind "nest" source
        leaf = bind "nestLeaf" int
        next = bind "nextNest" destination
        values = construct ints "List::Cons" [local leaf,construct ints "List::Nil" []]
        f = function "grow" [x] destination (match destination (local x)
          [branch "Nest::Stop" [leaf] (construct destination "Nest::Stop" [values]),
           branch "Nest::Next" [next] (local next)])
        out = bind "grown" destination
        group = bind "group" ints
        element = bind "element" int
        post = forallPayload (local out) [(group,Expr bool
          (AllElements (local group) element (binary Greater (local element) (literal 0))) origin)]
    check [nest] [f] [contract f out [positive "seed" int (local x)] [post]] `shouldBe` Right ()
  it "propagates parameter permutations across mutually recursive data" $ do
    let a = structure "A" ["a","b"]
          [variant "A" "End" [("value",variable "a")],
           variant "A" "Across" [("next",app "B" [variable "b",variable "a"])]]
        b = structure "B" ["x","y"]
          [variant "B" "End" [("value",variable "x")],
           variant "B" "Back" [("next",app "A" [variable "y",variable "x"])]]
        at = app "A" [int,int]
        bt = app "B" [int,int]
        x = bind "mutualInput" at
        av = bind "aValue" int
        bv = bind "bValue" int
        nextB = bind "nextB" bt
        nextA = bind "nextA" at
        positiveMember = bind "positive" int
        negativeMember = bind "negative" int
        requirement = forallPayload (local x)
          [(positiveMember,binary Greater (local positiveMember) (literal 0)),
           (negativeMember,binary Less (local negativeMember) (literal 0))]
        make wrong = function "mutual" [x] rat (match rat (local x)
          [branch "A::End" [av] (binary Divide (literal 1) (local av)),
           branch "A::Across" [nextB] (match rat (local nextB)
             [branch "B::End" [bv] (binary Divide (literal 1)
                (if wrong then binary Add (local bv) (literal 1) else local bv)),
              branch "B::Back" [nextA]
                (Expr rat (ExternalCall (Id "mutual") [local nextA]) origin)])])
        out = bind "mutualResult" rat
    let good = make False
        bad = make True
    check [a,b] [good] [contract good out [requirement] []] `shouldBe` Right ()
    check [a,b] [bad] [contract bad out [requirement] []] `shouldSatisfy` isLeft
  it "retains recursive guarantees through guarded nested presence projections" $ do
    let wrapped = structure "Wrapped" ["a"]
          [variant "Wrapped" "Leaf" [("value",variable "a")],
           variant "Wrapped" "Next" [("child",app "Nullable"
             [app "Optional" [app "Wrapped" [variable "a"]]])]]
        wt = app "Wrapped" [int]
        optional = app "Optional" [wt]
        nullable = app "Nullable" [optional]
        x = bind "wrapped" wt
        n = bind "wrappedLeaf" int
        field = bind "wrappedChild" nullable
        present value = Expr bool (Helper IsPresent [value]) origin
        outer = Expr optional (Helper PresentValue [local field]) origin
        inner = Expr wt (Helper PresentValue [outer]) origin
        pre = positive "wrappedMember" int (local x)
        call = Expr bool (ExternalCall (Id "walkWrapped") [inner]) origin
        guarded = Expr bool (ShortCircuit Or
          (Expr bool (Unary Not (present (local field))) origin)
          (Expr bool (ShortCircuit Or
            (Expr bool (Unary Not (present outer)) origin) call) origin)) origin
        make body = function "walkWrapped" [x] bool (match bool (local x)
          [branch "Wrapped::Leaf" [n]
            (binary Greater (binary Divide (literal 1) (local n)) (literal 0)),
           branch "Wrapped::Next" [field] body])
        out = bind "wrappedResult" bool
        good = make guarded
        bad = make call
    check [wrapped] [good] [contract good out [pre] []] `shouldBe` Right ()
    check [wrapped] [bad] [contract bad out [pre] []] `shouldSatisfy` isLeft
  it "activates presence implications only when their exact guard holds" $ do
    let optional = app "Nullable" [int]
        a = bind "guardA" optional
        b = bind "guardB" optional
        present binder = Expr bool (Helper IsPresent [local binder]) origin
        absentA = Expr bool (Unary Not (present a)) origin
        pre = Expr bool (ShortCircuit Or absentA (present b)) origin
        value = Expr int (Helper PresentValue [local b]) origin
        equal = binary Equal value value
        guarded = Expr bool (ShortCircuit Or absentA equal) origin
        make body = function "presence" [a,b] bool body
        out = bind "presenceResult" bool
        good = make guarded
        bad = make equal
    check [] [good] [contract good out [pre] []] `shouldBe` Right ()
    check [] [bad] [contract bad out [pre] []] `shouldSatisfy` isLeft
  it "admits constructor payload contracts and enforces them on finite recursive values" $ do
    let field = bind "Pack::Pack::tree" ty
        packType = app "Pack" []
        pack = structure "Pack" []
          [(variant "Pack" "Pack" [("tree",ty)])
            {constructorPredicates=[positive "packedMember" int (local field)]}]
        registry = either error id (makeRegistry [tree,pack])
        leaf value = DataValue ty (Id "Tree::Leaf")
          [ScalarValue (SInteger "Int8" value),ScalarValue (SInteger "Int8" 0)]
        wrapped value = DataValue packType (Id "Pack::Pack")
          [DataValue ty (Id "Tree::Node") [leaf value]]
    let packed = bind "packedInput" packType
        childTree = bind "packedTree" ty
        unpack = function "unpack" [packed] rat
          (match rat (local packed)
            [branch "Pack::Pack" [childTree] (call (local childTree))])
        reciprocalDefinition = reciprocal n
    check [tree,pack] [reciprocalDefinition,unpack] [law reciprocalDefinition]
      `shouldBe` Right ()
    forM_ [32,64] $ \bits -> do
      validateValueWithContracts registry bits packType (wrapped 1)
        `shouldBe` Right (wrapped 1)
      validateValueWithContracts registry bits packType (wrapped 0) `shouldSatisfy` isLeft
  it "audits ordered constructor payload predicates before assuming their guarantees" $ do
    let field = bind "Pack::Pack::tree" ty
        member = bind "nonzeroMember" int
        partial = forallPayload (local field)
          [(member,binary Greater (binary Divide (literal 1) (local member)) (literal 0))]
        nonzero = positive "nonzeroLeaf" int (local field)
        pack conditions = structure "Pack" []
          [(variant "Pack" "Pack" [("tree",ty)]) {constructorPredicates=conditions}]
    check [tree,pack [nonzero,partial]] [] [] `shouldBe` Right ()
    check [tree,pack [partial,nonzero]] [] [] `shouldSatisfy` isLeft
  it "rejects self-validating and mutually circular constructor callbacks" $ do
    let boxType name = app name []
        holder name other =
          let fieldType = app "Tree" [boxType other]
              field = bind (name ++ "::Wrap::tree") fieldType
              member = bind (name ++ "Member") (boxType other)
              nested = bind (name ++ "Nested") (app "Tree" [boxType name])
              predicate = forallPayload (local field) [(member,
                match bool (local member)
                  [branch (other ++ "::Empty") [] (truth True),
                   branch (other ++ "::Wrap") [nested] (truth True)])]
          in structure name []
            [variant name "Empty" [],
             (variant name "Wrap" [("tree",fieldType)]) {constructorPredicates=[predicate]}]
        self = holder "Self" "Self"
    let isCycle result = case result of
          Left diagnostics -> "cyclic constructor predicates" `isInfixOf` show diagnostics
          Right () -> False
        a = holder "A" "B"
        b = holder "B" "A"
        independent = b {dataConstructors=
          [c {constructorPredicates=[]} | c <- dataConstructors b]}
    check [tree,a,independent] [] [] `shouldBe` Right ()
    check [tree,self] [] [] `shouldSatisfy` isCycle
    check [tree,a,b] [] [] `shouldSatisfy` isCycle
  it "keeps payload callback substitution capture-avoiding" $ do
    let schema = P.fromRegistry (either error id (makeRegistry [tree]))
        x = Id "x"
        bound = Id "member"
        proof = T.AllPayloads schema "Tree" (T.Variable x)
          [(bound,T.ExactComparison Greater (T.Variable bound) (T.Variable x))]
        actual = T.substituteProof (M.singleton x (T.Variable bound)) proof
    case actual of
      T.AllPayloads _ _ (T.Variable free) [(fresh,T.ExactComparison Greater (T.Variable used) (T.Variable outer))] -> do
        free `shouldBe` bound
        outer `shouldBe` bound
        used `shouldBe` fresh
        fresh `shouldNotBe` bound
      _ -> expectationFailure (show actual)
