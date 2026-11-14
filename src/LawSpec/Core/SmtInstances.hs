-- | A collection operation as the solver sees it: the capability instance's
-- definition (LawSpec.Instances), made first-order for the function written
-- at the operation, as SPARK specialises a higher-order call and Why3's
-- eliminate_epsilon lifts a function with what it captures. The definition
-- is ordinary Core, so the encoding declares, unfolds and inducts over it as
-- it does any recursive definition. ref:DEC-capability-instances
module LawSpec.Core.SmtInstances (Instance(..), Written(..), instanceOf, instanceKey, instanceArguments) where

import Data.List (nub)
import qualified Data.Map.Strict as M
import LawSpec.Core
import LawSpec.Scalar (Scalar(..))

-- | One operation at one place: the instance operation it is, its
-- definition under a given name, the locals its function uses from around
-- it, the operands this place passes after them, and the function written
-- here.
data Instance = Instance
  { instanceOperation :: String
  , instanceDefinition :: Id -> Definition
  , instanceCaptures :: [Expr]
  , instanceOperands :: [Expr]
  , instanceFunction :: Maybe Written }

-- | The function written at an operation: of each element (and whether the
-- operation stops at the first element it rejects), or a fold's step, of
-- the accumulator and an element, from the first element or from the last.
data Written = OfElement Bool Binder Expr | Step Bool Binder Binder Expr

instanceArguments :: Instance -> [Expr]
instanceArguments found = instanceCaptures found ++ instanceOperands found

-- | Equal for two places exactly when their definitions are the same up to
-- the names of their binders, so they share one solver function.
instanceKey :: Instance -> String
instanceKey found = instanceOperation found ++ " " ++ show (instanceDefinition found (Id ""))

instanceOf :: Expr -> Maybe Instance
instanceOf source = case expressionNode source of
  MapElements list binder body | isList list ->
    Just (elementwise "mapList" list binder body (\_ value rest -> cons [value, rest]))
  FilterElements list binder body | isList list ->
    Just (elementwise "filterList" list binder body (\element keep rest ->
      Expr result (If keep (cons [element, rest]) rest) generated))
  AllElements list binder body | isList list ->
    Just (elementwise "allList" list binder body (\_ holds rest ->
      Expr result (ShortCircuit And holds rest) generated))
  FoldElements fromLeft list initial accumulator binder body | isList list ->
    let lifted = lift [(binderId accumulator, accumulatorId), (binderId binder, elementId)] body
        element = Binder elementId "element" (binderType binder)
        start = Binder (if fromLeft then accumulatorId else initialId) "initial" (binderType accumulator)
        listBinder = Binder listId "list" (expressionType list)
        rest = Binder restId "rest" (expressionType list)
        parameters = liftedCaptures lifted ++ [start, listBinder]
        define name =
          let self arguments = Expr result (ExternalCall name (map local (liftedCaptures lifted) ++ arguments)) generated
              step | fromLeft = self [liftedBody lifted, local rest]
                   | otherwise = Expr result (Let (Binder accumulatorId "accumulator" (binderType accumulator))
                       (self [local start, local rest]) (liftedBody lifted)) generated
          in definition name parameters result (matchList listBinder element rest (local start) step)
    in Just (Instance (if fromLeft then "foldLeftList" else "foldRightList") define
         (liftedArguments lifted) [initial, list] (Just (Step fromLeft accumulator binder body)))
  Helper Length [list] | isList list, Constructor name [] <- result, Just elementType <- elementOf list ->
    let listBinder = Binder listId "list" (expressionType list)
        element = Binder elementId "element" elementType
        rest = Binder restId "rest" (expressionType list)
        number n = Expr result (Constant (SInteger name n)) generated
        define self = definition self [listBinder] result (matchList listBinder element rest (number 0)
          (Expr result (Binary Add (Numeric result) (number 1) (Expr result (ExternalCall self [local rest]) generated)) generated))
    in Just (Instance "lengthList" define [] [list] Nothing)
  Helper Append [left, right] | isList left, Just elementType <- elementOf left ->
    let listBinder = Binder listId "list" (expressionType left)
        other = Binder initialId "other" (expressionType left)
        element = Binder elementId "element" elementType
        rest = Binder restId "rest" (expressionType left)
        define self = definition self [listBinder, other] result (matchList listBinder element rest (local other)
          (cons [local element, Expr result (ExternalCall self [local rest, local other]) generated]))
    in Just (Instance "appendList" define [] [left, right] Nothing)
  _ -> Nothing
  where
    result = expressionType source
    cons fields = Expr result (Construct (Id "List::Cons") fields) generated
    -- An operation of one function of the element: the definition matches
    -- the list, and its Cons case is built from the element, the function's
    -- value there and the operation on the rest.
    elementwise operation list binder body consCase =
      let lifted = lift [(binderId binder, elementId)] body
          element = Binder elementId "element" (binderType binder)
          listBinder = Binder listId "list" (expressionType list)
          rest = Binder restId "rest" (expressionType list)
          define name =
            let self = Expr result (ExternalCall name (map local (liftedCaptures lifted) ++ [local rest])) generated
                empty = case result of
                  Constructor "Bool" [] -> Expr result (Constant (SBool True)) generated
                  _ -> Expr result (Construct (Id "List::Nil") []) generated
            in definition name (liftedCaptures lifted ++ [listBinder]) result
                 (matchList listBinder element rest empty (consCase (local element) (liftedBody lifted) self))
      in Instance operation define (liftedArguments lifted) [list] (Just (OfElement (operation == "allList") binder body))

isList :: Expr -> Bool
isList e = elementOf e /= Nothing

elementOf :: Expr -> Maybe Type
elementOf e = case expressionType e of
  Constructor "List" [TypeArgument element] -> Just element
  _ -> Nothing

generated :: Origin
generated = GeneratedFrom (Id "lawspec.instances")

local :: Binder -> Expr
local b = Expr (binderType b) (Local (binderId b)) generated

matchList :: Binder -> Binder -> Binder -> Expr -> Expr -> Expr
matchList list element rest empty step = Expr (expressionType step)
  (Match (local list) [MatchCase (Id "List::Nil") [] empty, MatchCase (Id "List::Cons") [element, rest] step]) generated

definition :: Id -> [Binder] -> Type -> Expr -> Definition
definition name parameters result body =
  Definition (Declaration name (idText name) (foldr (Arrow . binderType) result parameters) generated) parameters body

listId, restId, elementId, accumulatorId, initialId :: Id
listId = Id "lawspec.instances::list"
restId = Id "lawspec.instances::rest"
elementId = Id "lawspec.instances::element"
accumulatorId = Id "lawspec.instances::accumulator"
initialId = Id "lawspec.instances::initial"

-- | A function written at an operation, closed: the locals it uses from
-- around it become parameters, in the order it first uses them, and every
-- binder is named by position, so two functions written alike are equal.
data Lifted = Lifted { liftedCaptures :: [Binder], liftedArguments :: [Expr], liftedBody :: Expr }

lift :: [(Id, Id)] -> Expr -> Lifted
lift applied body = Lifted
  [Binder (Id ("lawspec.instances::capture" ++ show i)) "capture" t | (i, (_, t)) <- zip [0 :: Int ..] captured]
  [Expr t (Local original) (expressionOrigin body) | (original, t) <- captured]
  (rename (\i -> M.findWithDefault i i table) body)
  where
    captured = [(i, t) | i <- nub (freeBinders body), i `notElem` map fst applied, Just t <- [lookup i (localTypes body)]]
    inner = nub (boundIn body)
    table = M.fromList (applied ++
      [(original, Id ("lawspec.instances::capture" ++ show i)) | (i, (original, _)) <- zip [0 :: Int ..] captured] ++
      [(original, Id ("lawspec.instances::inner" ++ show i)) | (i, original) <- zip [0 :: Int ..] inner])

localTypes :: Expr -> [(Id, Type)]
localTypes e = case expressionNode e of
  Local i -> [(i, expressionType e)]
  _ -> concatMap localTypes (children e)

-- | The binders an expression introduces, in the order it is read.
boundIn :: Expr -> [Id]
boundIn e = map binderId (nodeBinders (expressionNode e)) ++ concatMap boundIn (children e)

nodeBinders :: Node -> [Binder]
nodeBinders node = case node of
  Match _ cases -> concatMap caseBinders cases
  AllElements _ binder _ -> [binder]
  MapElements _ binder _ -> [binder]
  FilterElements _ binder _ -> [binder]
  FoldElements _ _ _ accumulator binder _ -> [accumulator, binder]
  SearchElements _ _ binder _ -> [binder]
  AllPayloads _ predicates -> map fst predicates
  Let binder _ _ -> [binder]
  _ -> []

-- | An expression with every local and binder renamed, and no trace of where
-- it was written.
rename :: (Id -> Id) -> Expr -> Expr
rename f e = renamed { expressionNode = node, expressionOrigin = generated }
  where
    renamed = mapChildren (rename f) e
    binder b = b { binderId = f (binderId b), binderName = "local" }
    node = case expressionNode renamed of
      Local i -> Local (f i)
      Match value cases -> Match value [c { caseBinders = map binder (caseBinders c) } | c <- cases]
      AllElements value b body -> AllElements value (binder b) body
      MapElements value b body -> MapElements value (binder b) body
      FilterElements value b body -> FilterElements value (binder b) body
      FoldElements fromLeft value initial accumulator b body -> FoldElements fromLeft value initial (binder accumulator) (binder b) body
      SearchElements universal value b body -> SearchElements universal value (binder b) body
      AllPayloads value predicates -> AllPayloads value [(binder b, x) | (b, x) <- predicates]
      Let b value body -> Let (binder b) value body
      other -> other
