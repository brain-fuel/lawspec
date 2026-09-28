-- Checked structural values; no property-framework dependencies.
module LawSpecSchema
  ( TypeRef(..), Field(..), Constructor(..), Definition(..), Schema
  , FieldPredicate, ValidationFailure(..), failureMessage
  , create, createWithContracts, hasContracts, checkType
  , constructors, substitute
  , validate, validateWith, validateChecked
  , allPayloads, allPayloadsWith
  , construct, constructWith, equal, equalWith, match, matchWith
  ) where

import Control.Monad (unless, forM_, zipWithM)
import Data.List (find, nub)
import qualified LawSpecRuntime as LS

data TypeRef = Parameter Int | Named String [TypeRef]
  deriving (Eq, Ord, Show)
data Field = Field String TypeRef deriving (Eq, Show)
data Constructor = Constructor String [Field] deriving (Eq, Show)
data Definition = Definition String Int [Constructor] deriving (Eq, Show)
type FieldPredicate =
  Schema -> [TypeRef] -> [LS.Scalar] -> Int -> Maybe LS.SymbolContext
  -> Either String Bool

data ValidationFailure
  = Rejected String
  | EvaluationFailure String
  deriving (Eq, Show)

failureMessage :: ValidationFailure -> String
failureMessage (Rejected message) = message
failureMessage (EvaluationFailure message) = message

data Schema = Schema [Definition] [(String, Int)] [(String, [FieldPredicate])]

hasContracts :: Schema -> Bool
hasContracts (Schema _ _ contracts) = any (not . null . snd) contracts

create :: [Definition] -> [String] -> Either String Schema
create definitions primitives = createWithContracts definitions primitives []

createWithContracts :: [Definition] -> [String] -> [(String, [FieldPredicate])]
                    -> Either String Schema
createWithContracts definitions primitives contracts = do
  let builtins = [(name, 0) | name <- primitives] ++
        [("List", 1), ("Maybe", 1), ("Either", 2),
         ("Nullable", 1), ("Optional", 1)]
      arities = builtins ++
        [(name, count) | Definition name count _ <- definitions]
      names = map fst arities
      tags = [tag | Definition _ _ variants <- definitions,
                    Constructor tag _ <- variants]
      schema = Schema definitions arities contracts
  unless (all (not . null) names && length names == length (nub names))
    (Left "duplicate or empty schema type")
  unless (all (not . null) tags && length tags == length (nub tags))
    (Left "duplicate or empty constructor identity")
  let contractTags = map fst contracts
  unless (length contractTags == length (nub contractTags) &&
          all (`elem` tags) contractTags)
    (Left "duplicate or unknown constructor contract")
  forM_ definitions $ \(Definition name parameters variants) -> do
    unless (parameters >= 0) (Left ("negative parameter count: " ++ name))
    forM_ variants $ \(Constructor tag fields) -> do
      let fieldNames = [field | Field field _ <- fields]
      unless (all (not . null) fieldNames &&
              length fieldNames == length (nub fieldNames))
        (Left ("duplicate or empty field: " ++ tag))
      forM_ fields $ \(Field _ typeRef) -> checkType schema parameters typeRef
  pure schema

checkType :: Schema -> Int -> TypeRef -> Either String ()
checkType _ count (Parameter index) =
  unless (index >= 0 && index < count) (Left "unbound schema parameter")
checkType schema@(Schema _ arities _) count (Named name arguments) = do
  unless (lookup name arities == Just (length arguments))
    (Left ("unknown type or wrong arity: " ++ name))
  mapM_ (checkType schema count) arguments

substitute :: [TypeRef] -> TypeRef -> TypeRef
substitute arguments (Parameter index) = arguments !! index
substitute arguments (Named name children) =
  Named name (map (substitute arguments) children)

constructors :: Schema -> TypeRef -> Either String (Maybe [Constructor])
constructors schema@(Schema definitions _ _) typeRef = do
  checkType schema 0 typeRef
  case typeRef of
    Named name arguments -> case
        find (\(Definition n _ _) -> n == name) definitions of
      Nothing -> pure Nothing
      Just (Definition _ _ variants) -> pure (Just
        [Constructor tag [Field field (substitute arguments ty) |
                          Field field ty <- fields] |
         Constructor tag fields <- variants])
    Parameter _ -> Left "unbound schema parameter"

validate :: Schema -> TypeRef -> Int -> LS.Scalar -> Either String LS.Scalar
validate schema = validateWith Nothing schema

validateWith :: Maybe LS.SymbolContext -> Schema -> TypeRef -> Int -> LS.Scalar
             -> Either String LS.Scalar
validateWith scope schema typeRef bits value =
  either (Left . failureMessage) Right
    (validateChecked scope schema typeRef bits value)

fromEvaluation :: Either String a -> Either ValidationFailure a
fromEvaluation = either (Left . EvaluationFailure) Right

failureContext :: String -> Either ValidationFailure a
               -> Either ValidationFailure a
failureContext label = either (Left . decorate) Right
  where
    decorate (Rejected message) = Rejected (label ++ ": " ++ message)
    decorate (EvaluationFailure message) =
      EvaluationFailure (label ++ ": " ++ message)

validateChecked :: Maybe LS.SymbolContext -> Schema -> TypeRef -> Int
                -> LS.Scalar -> Either ValidationFailure LS.Scalar
validateChecked scope schema@(Schema _ _ contracts) typeRef bits value = do
  unless (bits == 32 || bits == 64)
    (Left (EvaluationFailure "machineBits must be 32 or 64"))
  variants <- fromEvaluation (constructors schema typeRef)
  case variants of
    Just choices -> dataValue choices
    Nothing -> case (typeRef, value) of
      (Named "List" [element], LS.SList values) ->
        LS.SList <$> zipWithM (\index child ->
          failureContext ("List[" ++ show index ++ "]")
            (validateChecked scope schema element bits child))
          [0 :: Int ..] values
      (Named "Maybe" [element], _) -> dataValue
        [Constructor "Maybe::Nothing" [],
         Constructor "Maybe::Just" [Field "value" element]]
      (Named "Either" [left, right], _) -> dataValue
        [Constructor "Either::Left" [Field "value" left],
         Constructor "Either::Right" [Field "value" right]]
      (Named name [element], LS.SPresent wrapper payload)
        | name `elem` ["Nullable", "Optional"] && name == wrapper ->
          LS.SPresent wrapper <$> traverse
            (failureContext name . validateChecked scope schema element bits)
            payload
      (Named name [], _) | scalarPayload value && LS.scalarName value == name ->
        fromEvaluation (LS.validateScalar bits value)
      _ -> Left (EvaluationFailure
        ("invalid representation for " ++ show typeRef))
  where
    scalarPayload LS.SData{} = False
    scalarPayload LS.SList{} = False
    scalarPayload LS.SPresent{} = False
    scalarPayload _ = True
    dataValue choices = case value of
      LS.SData tag fields -> case
          find (\(Constructor name _) -> name == tag) choices of
        Nothing -> Left (EvaluationFailure
          ("unknown constructor " ++ tag ++ " for " ++ show typeRef))
        Just (Constructor _ expected) -> do
          unless (length fields == length expected)
            (Left (EvaluationFailure ("wrong field count: " ++ tag)))
          checked <- zipWithM
            (\(Field name ty) field -> failureContext (tag ++ "." ++ name)
              (validateChecked scope schema ty bits field)) expected fields
          let arguments = case typeRef of
                Named _ values -> values
                Parameter _ -> []
              predicates = maybe [] id (lookup tag contracts)
          forM_ (zip [1 :: Int ..] predicates) $ \(index, predicate) ->
            failureContext (tag ++ " predicate " ++ show index) $ do
              accepted <- fromEvaluation
                (predicate schema arguments checked bits scope)
              unless accepted
                (Left (Rejected "constructor field contract rejected"))
          pure (LS.SData tag checked)
      _ -> Left (EvaluationFailure
        ("expected constructor payload for " ++ show typeRef))


-- Recipes follow declared parameters, not equality of instantiated types.
data PayloadPlan
  = IgnorePayload
  | PayloadSlot Int
  | PayloadApplication String [PayloadPlan]

payloadRecipe :: [PayloadPlan] -> TypeRef -> PayloadPlan
payloadRecipe arguments (Parameter index) = arguments !! index
payloadRecipe arguments (Named name children) =
  let plans = map (payloadRecipe arguments) children
  in if all ignored plans then IgnorePayload else PayloadApplication name plans
  where
    ignored IgnorePayload = True
    ignored _ = False

allPayloads :: Schema -> TypeRef -> Int -> LS.Scalar
            -> [LS.Scalar -> Either String LS.Scalar]
            -> Either String LS.Scalar
allPayloads = allPayloadsWith Nothing

-- Either sequences full representation/contract validation before callbacks.
allPayloadsWith :: Maybe LS.SymbolContext -> Schema -> TypeRef -> Int
                -> LS.Scalar -> [LS.Scalar -> Either String LS.Scalar]
                -> Either String LS.Scalar
allPayloadsWith scope schema@(Schema definitions _ _) typeRef bits value
                predicates = do
  checkType schema 0 typeRef
  (name, arguments) <- case typeRef of
    Named name arguments
      | name `elem` ["List", "Maybe", "Either", "Nullable", "Optional"] ||
        any (\(Definition n _ _) -> n == name) definitions ->
          Right (name, arguments)
    _ -> Left "payload predicates require a data type"
  unless (length arguments == length predicates)
    (Left "payload predicate arity mismatch")
  checked <- validateWith scope schema typeRef bits value
  LS.SBool <$> walk
    (PayloadApplication name (map PayloadSlot [0 .. length arguments - 1]))
    checked
  where
    context label = either (Left . ((label ++ ": ") ++)) Right
    every [] = Right True
    every (step : steps) = do
      accepted <- step
      if accepted then every steps else Right False
    walk IgnorePayload _ = Right True
    walk (PayloadSlot index) stored = do
      result <- (predicates !! index) stored
      case result of
        LS.SBool accepted -> Right accepted
        _ -> Left "Bool required in payload predicate"
    walk (PayloadApplication name arguments) stored = case (name, stored) of
      ("List", LS.SList values) -> every
        [context ("List[" ++ show index ++ "]") (walk (head arguments) child)
        | (index, child) <- zip [0 :: Int ..] values]
      (_, LS.SPresent wrapper payload)
        | name `elem` ["Nullable", "Optional"] && wrapper == name ->
          maybe (Right True)
            (context (name ++ ".value") . walk (head arguments)) payload
      ("Maybe", LS.SData "Maybe::Nothing" []) -> Right True
      ("Maybe", LS.SData "Maybe::Just" [child]) ->
        context "Maybe::Just.value" (walk (head arguments) child)
      ("Either", LS.SData tag [child]) ->
        let index = if tag == "Either::Left" then 0 else 1
        in context (tag ++ ".value") (walk (arguments !! index) child)
      (_, LS.SData tag fields) -> do
        variants <- case find (\(Definition n _ _) -> n == name) definitions of
          Just (Definition _ _ variants) -> Right variants
          Nothing -> Left "unknown checked payload type"
        expected <- case find (\(Constructor n _) -> n == tag) variants of
          Just (Constructor _ expected) -> Right expected
          Nothing -> Left "unknown checked payload constructor"
        every [context (tag ++ "." ++ field)
          (walk (payloadRecipe arguments ty) child)
          | (Field field ty, child) <- zip expected fields]
      _ -> Left "invalid checked payload representation"

construct :: Schema -> TypeRef -> Int -> String -> [LS.Scalar]
          -> Either String LS.Scalar
construct = constructWith Nothing

constructWith :: Maybe LS.SymbolContext -> Schema -> TypeRef -> Int
              -> String -> [LS.Scalar] -> Either String LS.Scalar
constructWith scope schema typeRef bits tag fields = case typeRef of
  Named "List" [_] -> case (tag, fields) of
    ("List::Nil", []) -> validateWith scope schema typeRef bits (LS.SList [])
    ("List::Cons", [headValue, tailValue]) -> do
      checked <- validateWith scope schema typeRef bits tailValue
      case checked of
        LS.SList values -> validateWith scope schema typeRef bits
          (LS.SList (headValue : values))
        _ -> Left "invalid checked List representation"
    _ -> Left "invalid List constructor or field count"
  _ -> validateWith scope schema typeRef bits (LS.SData tag fields)

equal :: Schema -> TypeRef -> Int -> LS.Scalar -> LS.Scalar
      -> Either String Bool
equal = equalWith Nothing

equalWith :: Maybe LS.SymbolContext -> Schema -> TypeRef -> Int
          -> LS.Scalar -> LS.Scalar -> Either String Bool
equalWith scope schema typeRef bits left right = do
  a <- validateWith scope schema typeRef bits left
  b <- validateWith scope schema typeRef bits right
  pure (LS.equal a b)

-- Validation precedes branch selection; unselected branch functions stay lazy.
match :: Schema -> TypeRef -> Int -> LS.Scalar
      -> [(String, [LS.Scalar] -> a)] -> Either String a
match = matchWith Nothing

matchWith :: Maybe LS.SymbolContext -> Schema -> TypeRef -> Int -> LS.Scalar
          -> [(String, [LS.Scalar] -> a)] -> Either String a
matchWith scope schema typeRef bits value branches = do
  checked <- validateWith scope schema typeRef bits value
  (tag, fields) <- case checked of
    LS.SData name payload -> pure (name, payload)
    LS.SList [] -> pure ("List::Nil", [])
    LS.SList (headValue : tailValue) ->
      pure ("List::Cons", [headValue, LS.SList tailValue])
    _ -> Left "matching requires a data constructor"
  case lookup tag branches of
    Nothing -> Left ("missing checked match branch: " ++ tag)
    Just action -> pure (action fields)
