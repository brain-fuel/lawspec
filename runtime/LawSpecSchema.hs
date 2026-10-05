-- Checked structural values; no property-framework dependencies.
module LawSpecSchema
  ( TypeRef(..), Field(..), Constructor(..), Definition(..), Schema
  , FieldPredicate, ValidationFailure(..), failureMessage
  , create, createWithContracts, createIndexed, createRefined, withWitnesses, witnessedSchema, witnessText, hasContracts, checkType, fieldType
  , fieldTypeAt, witnessKeys, witnessed, witnessChoices, witnessPool, witnessKey, parseWitness
  , constructors, substitute
  , validate, validateWith, validateChecked
  , allPayloads, allPayloadsWith
  , construct, constructWith, equal, equalWith, match, matchWith
  ) where

import Control.Monad (unless, forM_, zipWithM, foldM)
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

-- Indexed families add, per constructor, their index terms then guards in
-- prefix notation over field indices; validation checks the guards.
-- GADT constructors add refinements (parameter, pattern) and an existential
-- count; existentials are parameters numbered after the definition's own.
-- Witnessed existentials (parameter numbers), by tag, are those only a value
-- determines; their types travel as the trailing Text witness fields.
data Schema = Schema [Definition] [(String, Int)] [(String, [FieldPredicate])] [(String, [String])]
  [(String, ([(Int, TypeRef)], Int))] [(String, [Int])]

hasContracts :: Schema -> Bool
hasContracts (Schema _ _ contracts _ _ _) = any (not . null . snd) contracts

create :: [Definition] -> [String] -> Either String Schema
create definitions primitives = createWithContracts definitions primitives []

createWithContracts :: [Definition] -> [String] -> [(String, [FieldPredicate])]
                    -> Either String Schema
createWithContracts definitions primitives contracts = createIndexed definitions primitives contracts []

createIndexed :: [Definition] -> [String] -> [(String, [FieldPredicate])] -> [(String, [String])]
              -> Either String Schema
createIndexed definitions primitives contracts indices = createRefined definitions primitives contracts indices []

createRefined :: [Definition] -> [String] -> [(String, [FieldPredicate])] -> [(String, [String])]
              -> [(String, ([(Int, TypeRef)], Int))] -> Either String Schema
createRefined definitions primitives contracts indices refinements = do
  let builtins = [(name, 0) | name <- primitives] ++
        [("List", 1), ("Maybe", 1), ("Either", 2),
         ("Nullable", 1), ("Optional", 1)]
      arities = builtins ++
        [(name, count) | Definition name count _ <- definitions]
      names = map fst arities
      tags = [tag | Definition _ _ variants <- definitions,
                    Constructor tag _ <- variants]
      schema = Schema definitions arities contracts indices refinements []
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
      let existentials = maybe 0 snd (lookup tag refinements)
      forM_ fields $ \(Field _ typeRef) -> checkType schema (parameters + existentials) typeRef
  pure schema

checkType :: Schema -> Int -> TypeRef -> Either String ()
checkType _ count (Parameter index) =
  unless (index >= 0 && index < count) (Left "unbound schema parameter")
checkType schema@(Schema _ arities _ _ _ _) count (Named name arguments) = do
  unless (lookup name arities == Just (length arguments))
    (Left ("unknown type or wrong arity: " ++ name))
  mapM_ (checkType schema count) arguments

substitute :: [TypeRef] -> TypeRef -> TypeRef
-- A witnessed existential stays open until a value supplies it.
substitute arguments (Parameter index)
  | index < length arguments = arguments !! index
  | otherwise = Parameter index
substitute arguments (Named name children) =
  Named name (map (substitute arguments) children)

constructors :: Schema -> TypeRef -> Either String (Maybe [Constructor])
constructors schema@(Schema definitions _ _ _ refinements _) typeRef = do
  checkType schema 0 typeRef
  case typeRef of
    Named name arguments -> case
        find (\(Definition n _ _) -> n == name) definitions of
      Nothing -> pure Nothing
      -- A GADT constructor whose refinements do not match these arguments
      -- builds no value of this type.
      Just (Definition _ parameters variants) -> pure (Just
        [Constructor tag [Field field (substitute extended ty) |
                          Field field ty <- fields] |
         Constructor tag fields <- variants,
         Just extended <- [refine (lookup tag refinements) parameters arguments]])
    Parameter _ -> Left "unbound schema parameter"

-- Arguments extended with the existentials a constructor's refinements bind;
-- Nothing when the refinements do not match.
refine :: Maybe ([(Int, TypeRef)], Int) -> Int -> [TypeRef] -> Maybe [TypeRef]
refine Nothing _ arguments = Just arguments
refine (Just (patterns, existentials)) parameters arguments = do
  bound <- foldM (\acc (index, pattern) -> match acc pattern (arguments !! index)) [] patterns
  let extra = [maybe (Parameter (parameters + k)) id (lookup (parameters + k) bound) | k <- [0 .. existentials - 1]]
  pure (arguments ++ extra)
  where
    match acc (Parameter index) actual
      | index < parameters = if arguments !! index == actual then Just acc else Nothing
      | otherwise = case lookup index acc of
          Just previous -> if previous == actual then Just acc else Nothing
          Nothing -> Just ((index, actual) : acc)
    match acc (Named name children) (Named other values)
      | name == other && length children == length values = foldM (\a (c, v) -> match a c v) acc (zip children values)
    match _ _ _ = Nothing

-- A constructor field's type at an instantiated type, its existentials
-- substituted.
fieldType :: Schema -> TypeRef -> String -> Int -> TypeRef
fieldType schema typeRef tag index = case constructors schema typeRef of
  Right (Just variants) | Constructor _ fields : _ <- [v | v@(Constructor t _) <- variants, t == tag]
                        , Field _ ty : _ <- drop index fields -> ty
  _ -> error ("constructor " ++ tag ++ " is not a value of " ++ show typeRef)

witnessedSchema :: [(String, [Int])] -> Either String Schema -> Either String Schema
witnessedSchema witnesses = fmap (withWitnesses witnesses)

-- A witness field's key, for generated codecs; the schema has checked it.
witnessText :: LS.Scalar -> String
witnessText (LS.SSequence "Text" units) = map toEnum units
witnessText _ = error "type witness must be text"

withWitnesses :: [(String, [Int])] -> Schema -> Schema
withWitnesses witnesses (Schema a b c d e w) = Schema a b c d e (w ++ witnesses)

-- Types a generator may choose for an existential that only a value fixes.
witnessPool :: [TypeRef]
witnessPool = [Named "Bool" [], Named "Int32" []]

-- A witness spells a type as its name, or a parenthesized application.
witnessKey :: TypeRef -> String
witnessKey (Named name []) = name
witnessKey (Named name arguments) = "(" ++ unwords (name : map witnessKey arguments) ++ ")"
witnessKey (Parameter index) = "?" ++ show index

parseWitness :: String -> Either String TypeRef
parseWitness text = case readType (words (concatMap spaced text)) of
  Just (ty, []) -> Right ty
  _ -> Left "malformed type witness"
  where
    spaced c = if c `elem` "()" then [' ', c, ' '] else [c]
    readType ("(" : name : rest) = arguments [] rest
      where
        arguments acc (")" : more) = Just (Named name (reverse acc), more)
        arguments acc more = readType more >>= \(child, after) -> arguments (child : acc) after
    readType (token : rest) | token /= ")" = Just (Named token [], rest)
    readType _ = Nothing

-- The trailing witness keys of a value's fields.
witnessKeys :: Schema -> String -> [LS.Scalar] -> Either String [String]
witnessKeys (Schema _ _ _ _ _ witnesses) tag fields = case lookup tag witnesses of
  Nothing -> Right []
  Just indices -> mapM key (drop (length fields - length indices) fields)
  where
    key (LS.SSequence "Text" units) = Right (map toEnum units)
    key _ = Left "type witness must be text"

-- Field types with witnessed existentials read from the given keys.
witnessed :: Schema -> String -> [TypeRef] -> [String] -> Either String [TypeRef]
witnessed schema@(Schema _ _ _ _ _ witnesses) tag types keys = case lookup tag witnesses of
  Nothing -> Right types
  Just indices -> do
    parsed <- mapM parseWitness keys
    mapM_ (checkType schema 0) parsed
    let size = if null indices then 0 else maximum indices + 1
        known = [maybe (Parameter i) id (lookup i (zip indices parsed)) | i <- [0 .. size - 1]]
    pure (map (substitute known) types)

-- Each choice of witnesses from the pool: the declared fields at it, and the
-- witness values.
witnessChoices :: Schema -> Constructor -> Either String [([Field], [LS.Scalar])]
witnessChoices schema@(Schema _ _ _ _ _ witnesses) (Constructor tag fields) = case lookup tag witnesses of
  Nothing -> Right [(fields, [])]
  Just indices -> do
    let declared = take (length fields - length indices) fields
    mapM (\choice -> do
      let keys = map witnessKey choice
      types <- witnessed schema tag [ty | Field _ ty <- declared] keys
      pure ([Field name ty | (Field name _, ty) <- zip declared types], map LS.textScalar keys))
      (mapM (const witnessPool) indices)

-- A field's type at a value's witness keys, for generated codecs.
fieldTypeAt :: Schema -> TypeRef -> String -> Int -> [String] -> TypeRef
fieldTypeAt schema typeRef tag index keys = case constructors schema typeRef of
  Right (Just variants) | Constructor _ fields : _ <- [v | v@(Constructor t _) <- variants, t == tag]
                        , Right types <- witnessed schema tag [ty | Field _ ty <- fields] keys
                        , ty : _ <- drop index types -> ty
  _ -> error ("constructor " ++ tag ++ " is not a value of " ++ show typeRef)

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

-- Prefix index terms: c<n>, f<field>[.<index>] and natural operators.
data IndexTerm = IndexConstant Integer | IndexField Int Int | IndexOp String IndexTerm IndexTerm

isIndexGuard :: String -> Bool
isIndexGuard text = take 1 (words text) `elem` [["=="], [">="]]

fieldTypes :: [Field] -> [TypeRef]
fieldTypes fields = [ty | Field _ ty <- fields]

parseIndexTerm :: [String] -> Either String (IndexTerm, [String])
parseIndexTerm tokens = case tokens of
  ('c' : digits) : rest -> Right (IndexConstant (read digits), rest)
  ('f' : digits) : rest -> case break (== '.') digits of
    (position, '.' : index) -> Right (IndexField (read position) (read index), rest)
    (position, _) -> Right (IndexField (read position) 0, rest)
  op : rest | op `elem` ["+", "-", "*", "div", "mod", "^"] -> do
    (a, afterA) <- parseIndexTerm rest
    (b, afterB) <- parseIndexTerm afterA
    Right (IndexOp op a b, afterB)
  _ -> Left "malformed index term"

-- Natural arithmetic; Nothing when an operation has no natural value.
evalIndexTerm :: (Int -> Int -> Either String Integer) -> IndexTerm -> Either String (Maybe Integer)
evalIndexTerm field term = case term of
  IndexConstant n -> Right (Just n)
  IndexField position index -> Just <$> field position index
  IndexOp op a b -> do
    left <- evalIndexTerm field a
    right <- evalIndexTerm field b
    pure $ do
      x <- left
      y <- right
      case op of
        "+" -> Just (x + y)
        "-" | x >= y -> Just (x - y)
        "*" -> Just (x * y)
        "div" | y > 0 -> Just (x `div` y)
        "mod" | y > 0 -> Just (x `mod` y)
        "^" | y >= 0 && y <= 64 -> Just (x ^ y)
        _ -> Nothing

indexGuard :: (Int -> Int -> Either String Integer) -> String -> Either String Bool
indexGuard field text = case words text of
  relation : rest -> do
    (a, afterA) <- parseIndexTerm rest
    (b, _) <- parseIndexTerm afterA
    x <- evalIndexTerm field a
    y <- evalIndexTerm field b
    pure $ case (x, y) of
      (Just l, Just r) -> if relation == "==" then l == r else l >= r
      _ -> False
  [] -> Left "malformed index guard"

-- The index of a checked value, computed from its constructor's term.
indexOf :: Schema -> TypeRef -> LS.Scalar -> Int -> Either String Integer
indexOf schema@(Schema _ _ _ indices _ _) typeRef value index = case value of
  LS.SData tag children -> do
    variants <- constructors schema typeRef
    expected <- case [fields | Just choices <- [variants], Constructor name fields <- choices, name == tag] of
      fields : _ -> Right fields
      [] -> Left ("no index for " ++ show typeRef)
    let terms = filter (not . isIndexGuard) (maybe [] id (lookup tag indices))
    text <- if index < length terms then Right (terms !! index) else Left ("no index for " ++ show typeRef)
    (term, _) <- parseIndexTerm (words text)
    result <- evalIndexTerm (\position child -> indexOf schema (fieldTypes expected !! position) (children !! position) child) term
    maybe (Left ("index of " ++ tag ++ " has no natural value")) Right result
  _ -> Left ("no index for " ++ show typeRef)

validateChecked :: Maybe LS.SymbolContext -> Schema -> TypeRef -> Int
                -> LS.Scalar -> Either ValidationFailure LS.Scalar
validateChecked scope schema@(Schema _ _ contracts indices _ _) typeRef bits value = do
  unless (bits == 32 || bits == 64)
    (Left (EvaluationFailure "machineBits must be 32 or 64"))
  variants <- fromEvaluation (constructors schema typeRef)
  case (variants, value) of
    -- A handle is checked by its type alone; LawSpec never looks inside.
    (_, LS.SHandle label _) -> case typeRef of
      Named name [] | name == label -> pure value
      _ -> Left (EvaluationFailure ("a " ++ label ++ " handle is not a " ++ show typeRef))
    (Just choices, _) -> dataValue choices
    (Nothing, _) -> case (typeRef, value) of
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
          types <- fromEvaluation (witnessKeys schema tag fields >>= witnessed schema tag [ty | Field _ ty <- expected])
          checked <- zipWithM
            (\(Field name _, ty) field -> failureContext (tag ++ "." ++ name)
              (validateChecked scope schema ty bits field)) (zip expected types) fields
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
          forM_ [text | text <- maybe [] id (lookup tag indices), isIndexGuard text] $ \text -> do
            let field position index = indexOf schema (fieldTypes expected !! position) (checked !! position) index
            holds <- fromEvaluation (indexGuard field text)
            unless holds (Left (Rejected (tag ++ ": index guard " ++ text ++ " failed")))
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
allPayloadsWith scope schema@(Schema definitions _ _ _ _ _) typeRef bits value
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
      (_, LS.SHandle _ _) -> Right True
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
    ("List::Nil", []) -> pure (LS.SList [])
    ("List::Cons", [headValue, LS.SList values]) -> pure (LS.SList (headValue : values))
    _ -> Left "invalid List constructor or field count"
  _ -> either (Left . failureMessage) Right (shallowChecked scope schema typeRef bits (LS.SData tag fields))

-- A newly built node: its fields were checked when they were built, decoded
-- or drawn, and a deep check of each node would make recursion quadratic.
shallowChecked :: Maybe LS.SymbolContext -> Schema -> TypeRef -> Int -> LS.Scalar
               -> Either ValidationFailure LS.Scalar
shallowChecked scope schema@(Schema _ _ contracts indices _ _) typeRef bits value = do
  variants <- fromEvaluation (constructors schema typeRef)
  case (variants, value) of
    (Just choices, LS.SData tag fields) -> case find (\(Constructor name _) -> name == tag) choices of
      Nothing -> Left (EvaluationFailure ("unknown constructor " ++ tag ++ " for " ++ show typeRef))
      Just (Constructor _ expected) -> do
        unless (length fields == length expected)
          (Left (EvaluationFailure ("wrong field count: " ++ tag)))
        let arguments = case typeRef of
              Named _ values -> values
              Parameter _ -> []
        forM_ (zip [1 :: Int ..] (maybe [] id (lookup tag contracts))) $ \(index, predicate) ->
          failureContext (tag ++ " predicate " ++ show index) $ do
            accepted <- fromEvaluation (predicate schema arguments fields bits scope)
            unless accepted (Left (Rejected "constructor field contract rejected"))
        forM_ [text | text <- maybe [] id (lookup tag indices), isIndexGuard text] $ \text -> do
          let field position index = indexOf schema (fieldTypes expected !! position) (fields !! position) index
          holds <- fromEvaluation (indexGuard field text)
          unless holds (Left (Rejected (tag ++ ": index guard " ++ text ++ " failed")))
        pure value
    _ -> validateChecked scope schema typeRef bits value

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
matchWith _ _ _ _ value branches = do
  -- Values are checked where they are built, decoded or drawn.
  let checked = value
  (tag, fields) <- case checked of
    LS.SData name payload -> pure (name, payload)
    LS.SList [] -> pure ("List::Nil", [])
    LS.SList (headValue : tailValue) ->
      pure ("List::Cons", [headValue, LS.SList tailValue])
    _ -> Left "matching requires a data constructor"
  case lookup tag branches of
    Nothing -> Left ("missing checked match branch: " ++ tag)
    Just action -> pure (action fields)
