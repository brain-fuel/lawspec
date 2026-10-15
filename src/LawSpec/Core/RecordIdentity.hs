-- | Canonical identities for closed structural products. The descriptor is
-- independent of source order and locations; actual construction remains an
-- ordinary sequence of typed Core expressions.
module LawSpec.Core.RecordIdentity
  ( RecordField(..), RecordDescription(..), RecordDescriptor, describeRecord, descriptorBytes
  , descriptorDigest, descriptorDependencies, dependencyFingerprint
  , RecordInterner, emptyInterner, internRecord, internRecordWith
  , makeRecordDeclaration, validateRecordDeclaration, internRecordDeclarations
  , instantiateRecordDeclaration, rebuildRecordDeclaration
  , constructRecord
  ) where

import Control.Monad (foldM, unless)
import Data.Aeson (Value(..), encode, toJSON)
import qualified Data.ByteString as B
import qualified Data.ByteString.Lazy as BL
import Data.Char (ord, toLower)
import Data.List (nub, sort, sortOn)
import qualified Data.Text as T
import qualified Data.Text.Encoding as T
import qualified Data.Map.Strict as M
import qualified Data.Set as S
import LawSpec.Blake3 (blake3Hex)
import LawSpec.Core
import LawSpec.Digest (digest, digestHex)
import LawSpec.Scalar (Scalar(..), primitive, isNumeric)

-- | A restriction belongs to its field even when it mentions only another
-- field. This association cannot be recovered from a flat predicate list.
data RecordField = RecordField
  { recordFieldBinder :: Binder, recordFieldPredicates :: [Expr] }
  deriving (Eq, Show)

-- The constructor is private: bytes, digest and dependency list must agree.
data RecordDescriptor = RecordDescriptor
  { descriptorBytes :: B.ByteString, descriptorDigest :: String
  , descriptorDependencies :: [Id] }
  deriving (Eq, Show)

-- The permutation belongs to the use site, not the interned descriptor. Two
-- alpha-equivalent records can refer to different enclosing type parameters.
data RecordDescription = RecordDescription
  { recordDescriptor :: RecordDescriptor, recordParameters :: [Id] }
  deriving (Eq, Show)

-- | A versioned UTF-8 JSON array format. Arrays and decimal integer strings
-- avoid object-key ordering and machine-sized JSON-number differences.
-- Available parameters name enclosing bindings. Canonical first occurrence
-- determines the returned permutation; unused enclosing bindings do not affect
-- a record. Repeated uses still preserve the equality between field types.
describeRecord :: [Id] -> [RecordField] -> Either String RecordDescription
describeRecord parameters supplied = do
  unique "record type parameter" parameters
  unique "record field label" (map (binderName . recordFieldBinder) supplied)
  unique "record field identity" (map (binderId . recordFieldBinder) supplied)
  unless (all (not . null . binderName . recordFieldBinder) supplied)
    (Left "a record field label must be nonempty")
  let fields = sortOn (binderName . recordFieldBinder) supplied
      used = nub [identity | field <- fields, identity <- fieldTypeVariables field, identity `elem` parameters]
      scope = Scope (M.fromList (zip used [0..]))
        (M.fromList [(binderId binder,binderName binder) | RecordField binder _ <- fields]) M.empty 0
  entries <- mapM (fieldValue scope) fields
  let bytes = BL.toStrict (encode (tag "lawspec.record.v1" [toJSON (length used),toJSON entries]))
      dependencies = sort (nub (concatMap fieldDependencies fields))
  pure (RecordDescription (RecordDescriptor bytes (blake3Hex bytes) dependencies) used)
  where
    unique label xs = unless (length xs == S.size (S.fromList xs)) (Left ("duplicate " ++ label))
    fieldValue scope (RecordField binder predicates) =
      tag "field" <$> sequence [pure (toJSON (binderName binder)),typeValue scope (binderType binder),
        toJSON <$> mapM (expressionValue scope) predicates]

data Scope = Scope
  { typeBindings :: M.Map Id Int, fieldBindings :: M.Map Id String
  , valueBindings :: M.Map Id Int, nextBinding :: Int }

tag :: String -> [Value] -> Value
tag name values = toJSON (toJSON name : values)

integer :: Integer -> Value
integer = toJSON . show

typeValue :: Scope -> Type -> Either String Value
typeValue scope ty = case ty of
  Constructor name arguments -> tag "type" . (toJSON name :) <$> mapM argument arguments
  Arrow a b -> tag "function" <$> mapM (typeValue scope) [a,b]
  TypeVariable identity -> case M.lookup identity (typeBindings scope) of
    Just index -> pure (tag "parameter" [toJSON index])
    Nothing -> Left ("unbound record type parameter: " ++ idText identity)
  where
    argument (TypeArgument value) = tag "type-argument" . pure <$> typeValue scope value
    argument (IndexArgument (Natural n)) = pure (tag "natural" [integer n])
    argument (IndexArgument (IndexVariable identity)) = tag "index" . pure <$> localValue scope identity

localValue :: Scope -> Id -> Either String Value
localValue scope identity = case M.lookup identity (valueBindings scope) of
  Just index -> pure (tag "bound" [toJSON index])
  Nothing -> case M.lookup identity (fieldBindings scope) of
    Just label -> pure (tag "field-reference" [toJSON label])
    Nothing -> Left ("unbound record value: " ++ idText identity)

bind :: Scope -> [Binder] -> Either String ([Value],Scope)
bind scope binders = foldM step ([],scope) binders
  where
    step (types,current) binder = do
      ty <- typeValue current (binderType binder)
      let index = nextBinding current
      pure (types ++ [ty],current { valueBindings = M.insert (binderId binder) index (valueBindings current),
        nextBinding = index + 1 })

expressionValue :: Scope -> Expr -> Either String Value
expressionValue scope expression = do
  ty <- typeValue scope (expressionType expression)
  node <- case expressionNode expression of
    Constant value -> pure (tag "constant" [scalarValue value])
    Local identity -> localValue scope identity
    Construct identity values -> referenced "construct" identity values
    ExternalCall identity values -> referenced "call" identity values
    Binary operation evidence a b -> do
      evidence' <- case evidence of
        Numeric t -> tag "numeric" . pure <$> typeValue scope t
        Structural t -> tag "structural" . pure <$> typeValue scope t
      values <- mapM go [a,b]
      pure (tag "binary" (toJSON (show operation) : evidence' : values))
    Unary operation value -> tag "unary" . (toJSON (show operation) :) . pure <$> go value
    ShortCircuit operation a b -> tag "logical" . (toJSON (show operation) :) <$> mapM go [a,b]
    If condition yes no -> tag "if" <$> mapM go [condition,yes,no]
    Convert _ target value -> do
      target' <- typeValue scope target
      value' <- go value
      pure (tag "convert" [target',value'])
    Helper name values -> tag "helper" . (toJSON (show name) :) <$> mapM go values
    Project constructor index value -> tag "project" . (toJSON (idText constructor) :) . (toJSON index :) . pure <$> go value
    Update constructor index value field -> tag "update" . (toJSON (idText constructor) :) . (toJSON index :) <$> mapM go [value,field]
    Let binder value body -> do
      value' <- go value
      (types,inner) <- bind scope [binder]
      body' <- expressionValue inner body
      pure (tag "let" [toJSON types,value',body'])
    Match value cases -> do
      value' <- go value
      cases' <- mapM branch cases
      pure (tag "match" [value',toJSON cases'])
    AllElements value binder predicate -> do
      value' <- go value
      (types,inner) <- bind scope [binder]
      predicate' <- expressionValue inner predicate
      pure (tag "all-elements" [value',toJSON types,predicate'])
    AllPayloads value predicates -> do
      value' <- go value
      predicates' <- mapM callback predicates
      pure (tag "all-payloads" [value',toJSON predicates'])
    Perform operation values -> do
      operation' <- operationValue operation
      values' <- mapM go values
      pure (tag "perform" (operation':values'))
    Calls operation values -> do
      operation' <- operationValue operation
      values' <- traverse (mapM go) values
      pure (tag "calls" [operation',toJSON values'])
    Handle handling body -> do
      handling' <- case handling of
        CatchFailure ability -> tag "catch" . pure <$> abilityValue ability
        WithHandler ability handler -> tag "handler" . (: [handlerValue handler]) <$> abilityValue ability
      body' <- go body
      pure (tag "handle" [handling',body'])
  pure (tag "expression" [ty,node])
  where
    go = expressionValue scope
    referenced name identity values = tag name . (toJSON (idText identity) :) <$> mapM go values
    branch match = do
      -- A constructor pattern can introduce existential types. Their names
      -- are local to this branch, including when two siblings use one spelling.
      let fresh = nub [identity | binder <- caseBinders match, identity <- typeVariables (binderType binder),
            M.notMember identity (typeBindings scope)]
          scoped = scope { typeBindings = M.union (M.fromList (zip fresh [M.size (typeBindings scope)..])) (typeBindings scope) }
      (types,inner) <- bind scoped (caseBinders match)
      body <- expressionValue inner (caseBody match)
      pure (tag "case" [toJSON (idText (caseConstructor match)),toJSON (length fresh),toJSON types,body])
    callback (binder,predicate) = do
      (types,inner) <- bind scope [binder]
      body <- expressionValue inner predicate
      pure (tag "callback" [toJSON types,body])
    operationValue (Operation ability name) = tag "operation" . (: [toJSON name]) <$> abilityValue ability
    abilityValue (AbilityRef identity arguments) = tag "ability" . (toJSON (idText identity) :) <$> mapM (typeValue scope) arguments
    handlerValue ProductionHandler = tag "production" []
    handlerValue (SpecHandler identity) = tag "spec" [toJSON (idText identity)]
    handlerValue (RecordingHandler handler) = tag "recording" [handlerValue handler]

-- Literal spelling is gone after typing. Reduce the remaining representational
-- alternatives without identifying IEEE signed zeros or NaN payloads.
scalarValue :: Scalar -> Value
scalarValue scalar = case scalar of
  SInteger name value -> tag "integer" [toJSON name,integer value]
  SBool value -> tag "boolean" [toJSON value]
  SDecimal coefficient exponent -> let (c,e) = decimal coefficient exponent
    in tag "decimal" [integer c,integer e]
  SRational numerator denominator | denominator /= 0 ->
    let divisor = gcd numerator denominator * (if denominator < 0 then -1 else 1)
    in tag "rational" [integer (numerator `div` divisor),integer (denominator `div` divisor)]
  SRational numerator denominator -> tag "rational" [integer numerator,integer denominator]
  SFloat name bits -> tag "float" [toJSON name,toJSON (map toLower bits)]
  SComplex name real imaginary -> tag "complex" [toJSON name,scalarValue real,scalarValue imaginary]
  SPresent name value -> tag "presence" [toJSON name,maybe Null scalarValue value]
  SSequence name units -> tag "sequence" [toJSON name,toJSON (map (integer . toInteger) units)]
  SCharacter name value -> tag "character" [toJSON name,integer (toInteger value)]
  SSymbol identity description -> tag "symbol" [textUnits identity,textUnits description]
  SAbsent name -> tag "absence" [toJSON name]
  where
    textUnits = toJSON . map (integer . toInteger . ord)
    decimal 0 _ = (0,0)
    decimal c e | c `rem` 10 == 0 = decimal (c `quot` 10) (e+1)
                | otherwise = (c,e)

fieldDependencies :: RecordField -> [Id]
fieldDependencies (RecordField binder predicates) = typeDependencies (binderType binder) ++ concatMap expressionDependencies predicates

fieldTypeVariables :: RecordField -> [Id]
fieldTypeVariables (RecordField binder predicates) = typeVariables (binderType binder) ++ concatMap expressionTypeVariables predicates

typeVariables :: Type -> [Id]
typeVariables ty = case ty of
  TypeVariable identity -> [identity]
  Constructor _ arguments -> concat [typeVariables argument | TypeArgument argument <- arguments]
  Arrow a b -> typeVariables a ++ typeVariables b

expressionTypeVariables :: Expr -> [Id]
expressionTypeVariables expression = typeVariables (expressionType expression) ++ own ++
  concatMap expressionTypeVariables (children expression)
  where
    own = case expressionNode expression of
      Match _ cases -> concatMap (concatMap (typeVariables . binderType) . caseBinders) cases
      AllElements _ binder _ -> typeVariables (binderType binder)
      AllPayloads _ predicates -> concatMap (typeVariables . binderType . fst) predicates
      Let binder _ _ -> typeVariables (binderType binder)
      Binary _ evidence _ _ -> case evidence of Numeric ty -> typeVariables ty; Structural ty -> typeVariables ty
      Convert _ ty _ -> typeVariables ty
      Perform (Operation (AbilityRef _ arguments) _) _ -> concatMap typeVariables arguments
      Calls (Operation (AbilityRef _ arguments) _) _ -> concatMap typeVariables arguments
      Handle (CatchFailure (AbilityRef _ arguments)) _ -> concatMap typeVariables arguments
      Handle (WithHandler (AbilityRef _ arguments) _) _ -> concatMap typeVariables arguments
      _ -> []

typeDependencies :: Type -> [Id]
typeDependencies ty = case ty of
  TypeVariable _ -> []
  Arrow a b -> typeDependencies a ++ typeDependencies b
  Constructor name arguments -> [Id name | primitive name == Nothing] ++ concat
    [typeDependencies argument | TypeArgument argument <- arguments]

expressionDependencies :: Expr -> [Id]
expressionDependencies expression = typeDependencies (expressionType expression) ++ own ++
  concatMap expressionDependencies (children expression)
  where
    own = case expressionNode expression of
      Construct identity _ -> [identity]
      ExternalCall identity _ -> [identity]
      Match _ cases -> concat [caseConstructor branch : concatMap (typeDependencies . binderType) (caseBinders branch) | branch <- cases]
      AllElements _ binder _ -> typeDependencies (binderType binder)
      AllPayloads _ predicates -> concatMap (typeDependencies . binderType . fst) predicates
      Let binder _ _ -> typeDependencies (binderType binder)
      Binary _ evidence _ _ -> case evidence of Numeric ty -> typeDependencies ty; Structural ty -> typeDependencies ty
      Convert _ ty _ -> typeDependencies ty
      Project identity _ _ -> [identity]
      Update identity _ _ _ -> [identity]
      Perform operation _ -> operationDependencies operation
      Calls operation _ -> operationDependencies operation
      Handle (CatchFailure ability) _ -> abilityDependencies ability
      Handle (WithHandler ability handler) _ -> abilityDependencies ability ++ handlerDependencies handler
      _ -> []
    operationDependencies (Operation ability _) = abilityDependencies ability
    abilityDependencies (AbilityRef identity arguments) = identity : concatMap typeDependencies arguments
    handlerDependencies ProductionHandler = []
    handlerDependencies (SpecHandler identity) = [identity]
    handlerDependencies (RecordingHandler handler) = handlerDependencies handler

-- | Cache invalidation is deliberately separate from structural identity.
-- The caller supplies transitive fingerprints from the checked dependency
-- graph. A missing fingerprint cannot silently produce a reusable cache key.
dependencyFingerprint :: (Id -> Maybe String) -> RecordDescriptor -> Either String String
dependencyFingerprint resolve descriptor = do
  dependencies <- mapM entry (descriptorDependencies descriptor)
  pure (digestHex (digest (BL.toStrict (encode (tag "lawspec.record.dependencies.v1" (map toJSON dependencies))))))
  where
    entry identity = case resolve identity of
      Just fingerprint -> Right (idText identity,fingerprint)
      Nothing -> Left ("missing structural-record dependency fingerprint: " ++ idText identity)

newtype RecordInterner = RecordInterner (M.Map String RecordDescriptor) deriving (Eq, Show)

emptyInterner :: RecordInterner
emptyInterner = RecordInterner M.empty

internRecord :: RecordDescriptor -> RecordInterner -> Either String (RecordDescriptor,RecordInterner)
internRecord = internRecordWith descriptorDigest

-- | The alternate index function makes collision handling testable. Always
-- compare full stored descriptors, including when hashes are cryptographic.
internRecordWith :: (RecordDescriptor -> String) -> RecordDescriptor -> RecordInterner
  -> Either String (RecordDescriptor,RecordInterner)
internRecordWith index descriptor (RecordInterner table) = case M.lookup key table of
  Nothing -> Right (descriptor,RecordInterner (M.insert key descriptor table))
  Just stored | descriptorBytes stored == descriptorBytes descriptor -> Right (stored,RecordInterner table)
              | otherwise -> Left ("structural record digest collision: " ++ key)
  where key = index descriptor

-- | The same product representation used by the existing checked evaluator and
-- every native backend. The returned parameter permutation belongs to the
-- enclosing expression/type and is never stored in the shared interner.
makeRecordDeclaration :: [Id] -> [RecordField] -> Origin -> Either String (DataDeclaration,[Id])
makeRecordDeclaration available fields origin = do
  description <- describeRecord available fields
  let descriptor = recordDescriptor description
      parameters = recordParameters description
      identity = recordIdentity descriptor
      constructor = Id (idText identity ++ "::Record")
      canonicalParameters = [Id (idText identity ++ "::parameter::" ++ show n) | n <- [0..length parameters - 1]]
      parameterMap = M.fromList (zip parameters canonicalParameters)
      fieldMap = M.fromList [(binderId field,Id (idText constructor ++ "::" ++ binderName field)) | RecordField field _ <- fields]
      canonicalFields = [Binder (Id (idText constructor ++ "::" ++ binderName field)) (binderName field)
          (renameType parameterMap fieldMap (binderType field))
        | RecordField field _ <- sortOn (binderName . recordFieldBinder) fields]
      predicates = concatMap recordFieldPredicates fields
      groups = snd (foldl (\(offset,entries) (RecordField field conditions) ->
        (offset + length conditions,entries ++ [(binderName field,[offset..offset + length conditions - 1])])) (0,[]) fields)
      record = StructuralRecord (T.unpack (T.decodeUtf8 (descriptorBytes descriptor))) (sortOn fst groups)
      declaration = (DataDeclaration identity ("Record" ++ descriptorDigest descriptor) canonicalParameters
        [DataConstructor constructor "Record" canonicalFields (map (renameExpression parameterMap fieldMap) predicates) origin [] []]
        origin Nothing) { dataStructural = Just record }
  pure (declaration,parameters)

recordIdentity :: RecordDescriptor -> Id
recordIdentity descriptor = Id ("lawspec::structural::record::" ++ descriptorDigest descriptor)

-- | Substitute a record's parameters into its actual fields before computing
-- its identity. A generic record at Integer is the same structural product as
-- one written with Integer directly. The remaining arguments name the caller's
-- free parameters in the new declaration's canonical order.
--
-- This builds typed syntax; ordinary constructor admission still checks every
-- resulting declaration. Nested structural types must likewise be normalized
-- by the caller's type traversal.
instantiateRecordDeclaration :: DataDeclaration -> [Type] -> Origin
  -> Either String (DataDeclaration,[Type])
instantiateRecordDeclaration original arguments origin = do
  validateRecordDeclaration original
  _ <- maybe (Left "structural instantiation requires a record type") Right (dataStructural original)
  unless (length arguments == length (dataParameters original))
    (Left "wrong structural record type argument count")
  constructor <- case dataConstructors original of
    [value] -> Right value
    _ -> Left "a structural record requires one constructor"
  let replacements = M.fromList (zip (dataParameters original) arguments)
      substitute ty = case ty of
        TypeVariable identity -> M.findWithDefault ty identity replacements
        Constructor name args -> Constructor name [case argument of
          TypeArgument value -> TypeArgument (substitute value)
          other -> other | argument <- args]
        Arrow a b -> Arrow (substitute a) (substitute b)
      predicates = map (mapExpressionTypes substitute) (constructorPredicates constructor)
      available = nub (concatMap typeVariables arguments)
  (made,parameters) <- rebuildRecordDeclaration original available
    (map (substitute . binderType) (constructorFields constructor)) predicates origin
  pure (made,map TypeVariable parameters)

-- | Rebuild after a checked traversal changes field and predicate types. The
-- flat predicate sequence remains authoritative: canonical field ordering must
-- never move a guard after a partial operation. Remaining parameters belong to
-- the caller's scope, as in makeRecordDeclaration.
rebuildRecordDeclaration :: DataDeclaration -> [Id] -> [Type] -> [Expr] -> Origin
  -> Either String (DataDeclaration,[Id])
rebuildRecordDeclaration original available fieldTypes predicates origin = do
  validateRecordDeclaration original
  metadata <- maybe (Left "structural rebuilding requires a record type") Right (dataStructural original)
  constructor <- case dataConstructors original of
    [value] -> Right value
    _ -> Left "a structural record requires one constructor"
  unless (length fieldTypes == length (constructorFields constructor) &&
          length predicates == length (constructorPredicates constructor))
    (Left "structural rebuilding must retain every field and restriction")
  let fields = [RecordField (field{binderType=ty})
          [predicates !! index | index <- maybe [] id (lookup (binderName field) (structuralPredicates metadata))]
        | (field,ty) <- zip (constructorFields constructor) fieldTypes]
  (made,parameters) <- makeRecordDeclaration available fields origin
  let newConstructor = head (dataConstructors made)
      parameterMap = M.fromList (zip parameters (dataParameters made))
      fieldMap = M.fromList (zip (map binderId (constructorFields constructor))
        (map binderId (constructorFields newConstructor)))
      -- Rebuilding a descriptor groups restrictions by canonical field label.
      -- Restore the original execution order and its predicate indexes after
      -- renaming. In particular, retain guards preceding partial operations.
      restored = made{dataConstructors=[newConstructor{constructorPredicates=
        map (renameExpression parameterMap fieldMap) predicates}],
        dataStructural=fmap (\structure -> structure{structuralPredicates=structuralPredicates metadata}) (dataStructural made)}
  validateRecordDeclaration restored
  pure (restored,parameters)

-- Every occurrence of a type in an expression participates in substitution,
-- including capability evidence, lexical binders and effect arguments.
mapExpressionTypes :: (Type -> Type) -> Expr -> Expr
mapExpressionTypes transform expression = expression
  { expressionType=transform (expressionType expression)
  , expressionNode=case expressionNode (mapChildren (mapExpressionTypes transform) expression) of
      Binary operation evidence a b -> Binary operation (case evidence of
        Numeric ty -> Numeric (transform ty)
        Structural ty -> case transform ty of
          concrete@(Constructor name []) | operation `elem` [Equal,NotEqual],isNumeric name -> Numeric concrete
          concrete -> Structural concrete) a b
      Let binder value body -> Let (bound binder) value body
      Match value branches -> Match value [branch{caseBinders=map bound (caseBinders branch)} | branch <- branches]
      AllElements value binder predicate -> AllElements value (bound binder) predicate
      AllPayloads value predicates -> AllPayloads value [(bound binder,predicate) | (binder,predicate) <- predicates]
      Convert conversion ty value -> Convert conversion (transform ty) value
      Perform (Operation ref name) values -> Perform (Operation (ability ref) name) values
      Calls (Operation ref name) values -> Calls (Operation (ability ref) name) values
      Handle (CatchFailure ref) value -> Handle (CatchFailure (ability ref)) value
      Handle (WithHandler ref handler) value -> Handle (WithHandler (ability ref) handler) value
      other -> other }
  where
    bound binder=binder{binderType=transform (binderType binder)}
    ability (AbilityRef identity arguments)=AbilityRef identity (map transform arguments)

renameType :: M.Map Id Id -> M.Map Id Id -> Type -> Type
renameType parameters values ty = case ty of
  TypeVariable identity -> TypeVariable (M.findWithDefault identity identity parameters)
  Constructor name arguments -> Constructor name [case argument of
    TypeArgument value -> TypeArgument (renameType parameters values value)
    IndexArgument (IndexVariable identity) -> IndexArgument (IndexVariable (M.findWithDefault identity identity values))
    other -> other | argument <- arguments]
  Arrow a b -> Arrow (renameType parameters values a) (renameType parameters values b)

renameExpression :: M.Map Id Id -> M.Map Id Id -> Expr -> Expr
renameExpression parameters fields expression = expression
  { expressionType = ty (expressionType expression)
  , expressionNode = case expressionNode expression of
      Let bound value body -> Let (binder bound) (go value) (under [bound] body)
      Match value cases -> Match (go value)
        [branch { caseBinders = map binder (caseBinders branch),caseBody = under (caseBinders branch) (caseBody branch) } | branch <- cases]
      AllElements value bound predicate -> AllElements (go value) (binder bound) (under [bound] predicate)
      AllPayloads value predicates -> AllPayloads (go value) [(binder bound,under [bound] predicate) | (bound,predicate) <- predicates]
      _ -> node (expressionNode (mapChildren go expression)) }
  where
    go = renameExpression parameters fields
    ty = renameType parameters fields
    under binders = renameExpression parameters (foldr (M.delete . binderId) fields binders)
    binder value = value { binderType = ty (binderType value) }
    ability (AbilityRef identity arguments) = AbilityRef identity (map ty arguments)
    operation (Operation ref name) = Operation (ability ref) name
    evidence (Numeric value) = Numeric (ty value)
    evidence (Structural value) = Structural (ty value)
    node value = case value of
      Local identity -> Local (M.findWithDefault identity identity fields)
      Binary op ev a b -> Binary op (evidence ev) a b
      Convert conversion target expression' -> Convert conversion (ty target) expression'
      Perform op arguments -> Perform (operation op) arguments
      Calls op arguments -> Calls (operation op) arguments
      Handle (CatchFailure ref) body -> Handle (CatchFailure (ability ref)) body
      Handle (WithHandler ref handler) body -> Handle (WithHandler (ability ref) handler) body
      other -> other

-- | Recompute, rather than trust, stored descriptors at the registry boundary.
-- Nominal declarations never acquire a structural identity implicitly.
validateRecordDeclaration :: DataDeclaration -> Either String ()
validateRecordDeclaration declaration = case dataStructural declaration of
  Nothing -> pure ()
  Just metadata -> do
    unless (not (dataHandle declaration) && dataNative declaration == Nothing && dataIndex declaration == Nothing)
      (Left "a structural record cannot be a handle, bound nominal type or indexed family")
    constructor <- case dataConstructors declaration of
      [value] | null (constructorEquations value) && null (constructorExistentials value) -> Right value
      _ -> Left "a structural record requires exactly one ordinary product constructor"
    let fields = constructorFields constructor
        predicates = constructorPredicates constructor
        groups = structuralPredicates metadata
        indexes = concatMap snd groups
    unless (map binderName fields == sort (map binderName fields))
      (Left "structural record fields must use canonical label order")
    unless (sort (map fst groups) == map binderName fields && length groups == length fields)
      (Left "structural record restriction groups must name every field exactly once")
    unless (sort indexes == [0..length predicates - 1])
      (Left "structural record restriction groups must cover each predicate exactly once")
    unless (all (\(_,ordered) -> ordered == sort ordered) groups)
      (Left "structural record restriction groups must retain predicate evaluation order")
    description <- describeRecord (dataParameters declaration)
      [RecordField field [predicates !! index | index <- maybe [] id (lookup (binderName field) groups)] | field <- fields]
    let descriptor = recordDescriptor description
    unless (recordParameters description == dataParameters declaration)
      (Left "structural record parameters must use canonical first-occurrence order without unused parameters")
    unless (descriptorBytes descriptor == T.encodeUtf8 (T.pack (structuralDescriptor metadata)))
      (Left "stored structural record descriptor does not match its typed fields and restrictions")
    unless (dataId declaration == recordIdentity descriptor)
      (Left "structural record identity does not match its canonical descriptor")
    unless (dataName declaration == "Record" ++ descriptorDigest descriptor && constructorName constructor == "Record")
      (Left "structural record generated names must match their canonical descriptor")
    unless (constructorId constructor == Id (idText (dataId declaration) ++ "::Record"))
      (Left "structural record constructor identity does not match its type")

-- | Intern structural products across units, comparing full descriptors before
-- sharing a type. Duplicate nominal declarations remain registry errors.
internRecordDeclarations :: [DataDeclaration] -> Either String [DataDeclaration]
internRecordDeclarations declarations = reverse . snd <$> foldM step (M.empty,[]) declarations
  where
    step (seen,kept) declaration = do
      validateRecordDeclaration declaration
      case dataStructural declaration of
        Nothing -> pure (seen,declaration:kept)
        Just metadata -> case M.lookup (dataId declaration) seen of
          Nothing -> pure (M.insert (dataId declaration) metadata seen,declaration:kept)
          Just original | structuralDescriptor original == structuralDescriptor metadata -> pure (seen,kept)
                        | otherwise -> Left ("structural record digest collision: " ++ idText (dataId declaration))

-- | Values evaluate once in author order, then build the canonical product.
-- The caller supplies a fresh lexical prefix, as for other elaborated lets.
-- Intrinsic Core validation and constructor contracts still audit this term.
constructRecord :: Id -> DataDeclaration -> [Type] -> [(String,Expr)] -> Origin -> Either String Expr
constructRecord prefix declaration arguments values origin = do
  validateRecordDeclaration declaration
  unless (dataStructural declaration /= Nothing) (Left "a bare record value requires a structural record type")
  unless (length arguments == length (dataParameters declaration)) (Left "wrong structural record type argument count")
  constructor <- case dataConstructors declaration of
    [value] -> Right value
    _ -> Left "a structural record requires one constructor"
  let fields = constructorFields constructor
      supplied = map fst values
      labels = map binderName fields
  unless (length supplied == length (nub supplied) && sort supplied == labels)
    (Left "a structural record value must supply every declared field exactly once")
  let parameters = M.fromList (zip (dataParameters declaration) arguments)
      instantiated ty = case ty of
        TypeVariable identity -> M.findWithDefault ty identity parameters
        Constructor name args -> Constructor name [case argument of
          TypeArgument value -> TypeArgument (instantiated value)
          other -> other | argument <- args]
        Arrow a b -> Arrow (instantiated a) (instantiated b)
      fieldTypes = M.fromList [(binderName field,instantiated (binderType field)) | field <- fields]
  mapM_ (\(label,value) -> unless (M.lookup label fieldTypes == Just (expressionType value))
    (Left ("structural record field type mismatch: " ++ label))) values
  let result = Constructor (idText (dataId declaration)) (map TypeArgument arguments)
      -- Backends recognize ::let:: and preserve its suffix when naming a
      -- temporary. Include the fresh prefix's digest there as well, so two
      -- nested literals cannot acquire the same native local name.
      temporary = idText prefix ++ "::let::record" ++ blake3Hex (T.encodeUtf8 (T.pack (idText prefix))) ++ "::"
      lets = [(label,Binder (Id (temporary ++ show n)) label (expressionType value),value)
        | (n,(label,value)) <- zip [0::Int ..] values]
      locals = M.fromList [(label,Expr (binderType binder) (Local (binderId binder)) origin) | (label,binder,_) <- lets]
      body = Expr result (Construct (constructorId constructor) [locals M.! label | label <- labels]) origin
  pure (foldr (\(_,binder,value) rest -> Expr result (Let binder value rest) origin) body lets)
