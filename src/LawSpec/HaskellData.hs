-- | Native algebraic declarations are rendered from resolved Core identities.
module LawSpec.HaskellData (namesFor, requiresSchema, emitHaskellData, haskellDataType, haskellDataTypeWithRepresentations, haskellNativeTypeWithParameters, emitHaskellSchema, emitHaskellSchemaWithProfile, haskellTypeReference, emitHaskellCodecs, emitHaskellCodecsWithRepresentations, emitHaskellCodecsWithHooks, emitHaskellCodecsWithLayouts, haskellCodec, haskellCodecDoc, haskellCodecDocWithContext, haskellCodecDocIn, haskellCodecExpr, haskellTypeReferenceDoc, moduleImports, sortedImports, moduleText) where

import System.IO.Unsafe (unsafePerformIO)
import LawSpec.Memo (newPersistentTableByShow, Table, memoized)
import qualified LawSpec.Dependencies as Identity
import qualified LawSpec.Typed.EmissionContext as EmissionContext
import LawSpec.Core.Positional (positionalLabel)
import LawSpec.NativeBinding (ResolvedConstructorBinding(..), foldNativeLayoutM)
import LawSpec.DataNames (flatDataCandidates, productConstructors, caseInsensitiveCounts, ambiguous, fieldClosed)
import LawSpec.HaskellTypeRefs
import qualified LawSpec.HaskellExpr as E
import qualified LawSpec.Backend as Backend
import LawSpec.Core.Total (constructorProofContracts)
import Control.Monad (unless, forM)
import Data.Char (isAscii, isAlphaNum, isLetter, toUpper, toLower, ord)
import Data.List (nub, isInfixOf, zip4, intercalate, sort, sortOn)
import LawSpec.SourceLink (generatedHeader)
import LawSpec.RecordNames (recordDisplayNames)
import qualified Data.Map.Strict as M
import Numeric (showHex)
import qualified LawSpec.Core as C
import qualified LawSpec.Core.Schema as S
import LawSpec.Scalar (primitives, primitiveName, isInteger)
import LawSpec.Core.Types (makeRegistry, checkType, freeExistentials, keyedRequirements, equalityRequirements, substitute)
import LawSpec.Collections (collectionContainer)
import qualified LawSpec.Code.Doc as D
import qualified LawSpec.Code.Haskell as H

nativeDocumentTable :: Table (Either String [D.Doc])
nativeDocumentTable = unsafePerformIO (newPersistentTableByShow "public-haskell-data" (4 * 1024 * 1024))
{-# NOINLINE nativeDocumentTable #-}

codecDocumentTable :: Table (Either String D.Doc)
codecDocumentTable = unsafePerformIO (newPersistentTableByShow "public-haskell-codec" (8 * 1024 * 1024))
{-# NOINLINE codecDocumentTable #-}

type Names = [(C.Id,String)]

fieldIdentifier :: String -> Either String ()
fieldIdentifier name | Just _ <- positionalLabel name = pure ()
                     | otherwise = identifier name

capitalize :: String -> String
capitalize [] = []
capitalize (c:cs) = toUpper c:cs

identifier :: String -> Either String ()
identifier name = unless valid (Left ("invalid Haskell data identifier: " ++ name))
  where
    valid = case name of
      c:cs -> isAscii c && isLetter c && all (\x -> isAscii x && (isAlphaNum x || x == '_')) cs
      [] -> False

namesFor :: [C.DataDeclaration] -> Either String Names
namesFor given = do
  -- An anonymous record shows a name from where it is used (LawSpec.RecordNames).
  let display = recordDisplayNames given
      declarations = [maybe d (\n -> d {C.dataName = n}) (M.lookup (C.dataId d) display) | d <- given]
      qualified = flatDataCandidates capitalize (const False) declarations
      counts = caseInsensitiveCounts qualified
      names = [(identity, if ambiguous counts name then name ++ "_" ++ concatMap (\c -> showHex (ord c) "_") (C.idText identity) else name) | (identity,name) <- qualified]
  mapM_ (identifier . snd) names
  unless (all (== 1) (caseInsensitiveCounts names)) (Left "conflicting Haskell data identities")
  pure (names ++ productConstructors declarations names)

application :: String -> [String] -> String
application name [] = name
application name arguments = "(" ++ unwords (name : arguments) ++ ")"

typeText :: String -> Names -> [(C.Id,String)] -> C.Type -> Either String String
typeText scope names parameters ty = case ty of
  C.TypeVariable variable -> maybe (Left "unbound Haskell data parameter") Right (lookup variable parameters)
  -- Built-in collections are native (LawSpecCollectionCodecs).
  C.Constructor name arguments | Just short <- collectionContainer name -> do
    args <- mapM argument arguments
    pure $ case short of
      "Set" -> application "Set.Set" args
      "KeyVal" -> application "Map.Map" args
      _ -> application "Seq.Seq" args
  C.Constructor name arguments -> do
    args <- mapM argument arguments
    case lookup (C.Id name) names of
      Just native -> pure (application (scope ++ native) args)
      Nothing -> case (name,args) of
        ("List",[inner]) -> pure ("[" ++ inner ++ "]")
        ("Maybe",[_]) -> pure (application "P.Maybe" args)
        ("Either",[_,_]) -> pure (application "P.Either" args)
        ("Nullable",[_]) -> pure (application "LS.Nullable" args)
        ("Optional",[_]) -> pure (application "LS.Optional" args)
        (_,[]) -> maybe (Left ("no Haskell data representation for " ++ name)) Right (lookup name scalars)
        _ -> Left ("no Haskell data representation for " ++ show ty)
  _ -> Left ("no Haskell data representation for " ++ show ty)
  where
    argument (C.TypeArgument value) = typeText scope names parameters value
    argument _ = Left "indexed Haskell data is not supported"
    scalars = [("Bool","P.Bool"),("Integer","P.Integer"),("BigInt","P.Integer"),("BigUInt","P.Integer"),
      ("Int8","I.Int8"),("Int16","I.Int16"),("Int32","I.Int32"),("Int64","I.Int64"),
      ("UInt8","W.Word8"),("UInt16","W.Word16"),("UInt32","W.Word32"),("UInt64","W.Word64"),
      ("IntSize","P.Int"),("UIntSize","P.Word"),("UIntPtr","P.Word"),
      ("Decimal","LS.Decimal"),("Rational","P.Rational"),("Float32","P.Float"),("Float64","P.Double"),
      ("Complex64","(C.Complex P.Float)"),("Complex128","(C.Complex P.Double)"),
      ("Char","P.Char"),("CodePoint","P.Char"),("CodeUnit16","W.Word16"),
      ("Text","T.Text"),("CodePointText","LS.CodePointText"),("Utf16Text","LS.Utf16Text"),
      ("Bytes","B.ByteString"),("Symbol","LS.Symbol"),("Unit","()"),("Null","LS.Null"),("Undefined","LS.Undefined")]

-- | Types are checked against the registry before rendering, so an unknown type
-- is a compiler error rather than uncompilable Haskell.
haskellDataType :: [C.DataDeclaration] -> C.Type -> Either String String
haskellDataType declarations =
  -- The registry and the names depend only on the declarations: a caller
  -- that applies this to them once shares them across every type.
  let prepared = (,) <$> makeRegistry declarations <*> namesFor declarations
  in \ty -> do
  (registry, names) <- prepared
  checkType registry ty
  typeText "Data." names [] ty

-- | Bound native types replace generated ones wherever the type appears.
-- ref:DEC-native-bindings-typed-identity
haskellDataTypeWithRepresentations :: [C.DataDeclaration] -> [(C.Id,String)] -> C.Type -> Either String String
haskellDataTypeWithRepresentations declarations representations ty = do
  registry <- makeRegistry declarations
  checkType registry ty
  haskellNativeTypeWithParameters declarations representations [] ty

-- | Bound native types replace generated ones wherever the type appears.
-- ref:DEC-native-bindings-typed-identity
haskellNativeTypeWithParameters :: [C.DataDeclaration] -> [(C.Id,String)] -> [(C.Id,String)] -> C.Type -> Either String String
haskellNativeTypeWithParameters declarations representations parameters ty = do
  names <- namesFor declarations
  typeText "" [(identity, maybe ("Data." ++ name) id (lookup identity representations)) |
    (identity,name) <- names] parameters ty

-- | LawSpec data become ordinary Haskell algebraic data types.
-- ref:DEC-idiomatic-generated-types
emitHaskellData :: D.Layout -> [C.DataDeclaration] -> Either String String
emitHaskellData layout declarations = do
  registry <- makeRegistry declarations
  names <- namesFor declarations
  selectors <- selectorsFor names declarations
  -- Keyed data can be a Data.Set element or Data.Map key, so it is ordered
  -- natively too.
  let nativeEq = fieldClosed (all (null . C.constructorExistentials) . C.dataConstructors) declarations
      ordered declaration = fieldClosed (not . gadtDeclaration) declarations declaration && either (const False) (const True) (keyedRequirements registry
        (C.Constructor (C.idText (C.dataId declaration)) [C.TypeArgument (C.TypeVariable p) | p <- C.dataParameters declaration]))
  let graph = Identity.dependencyGraph declarations []
      cachedDefinition declaration =
        let selected = [entry | entry@((constructor,_),_) <- selectors,
              constructor `elem` map C.constructorId (C.dataConstructors declaration)]
            context = (nativeEq declaration,ordered declaration,selected)
        in memoized nativeDocumentTable
          (Identity.fullKey graph ("public-haskell-data:" ++ show context ++ EmissionContext.declarationContext graph declarations names declaration) declaration)
          (definition names selectors (nativeEq declaration) (ordered declaration) declaration)
  definitions <- mapM cachedDefinition [d | d <- declarations, collectionContainer (C.idText (C.dataId d)) == Nothing]
  let gadts = any gadtDeclaration declarations
  pure (moduleText layout "LawSpecData" ""
    (["EmptyDataDecls", "EmptyDataDeriving"] ++ (if gadts then ["GADTs", "StandaloneDeriving"] else []))
    [(m, Just a, Nothing) | (m, a) <- [("Prelude","P"),("Data.Int","I"),("Data.Word","W"),
          ("Data.Text","T"),("Data.ByteString","B"),("Data.Complex","C"),("LawSpecRuntime","LS"),
          ("Data.Set","Set"),("Data.Map.Strict","Map"),("Data.Sequence","Seq")]]
    (concat definitions))
  where
    -- A handle is the runtime's opaque handle: only adapters make one.
    definition names _ _ _ declaration | C.dataHandle declaration = do
      name <- lookupName names (C.dataId declaration)
      pure [D.text ("type " ++ name ++ " = LS.Handle")]
    definition names selectors _ _ declaration | gadtDeclaration declaration = gadtDefinition names selectors declaration
    definition names selectors equatable ordered declaration = do
      name <- lookupName names (C.dataId declaration)
      let parameters = zip (C.dataParameters declaration) ["a" ++ show n | n <- [0::Int ..]]
          header = unwords ("data" : name : map snd parameters)
          deriving' = D.text (if ordered then "deriving (P.Eq, P.Ord, P.Show)" else if equatable then "deriving (P.Eq, P.Show)" else "deriving (P.Show)")
      variants <- forM (C.dataConstructors declaration) $ \variant -> do
        constructor <- lookupName names (C.constructorId variant)
        let fieldNames = map (capitalize . C.binderName) (C.constructorFields variant)
        unless (length fieldNames == length (nub fieldNames)) (Left "Haskell constructor fields collide after naming")
        fields <- forM (C.constructorFields variant) $ \field -> do
          fieldIdentifier (C.binderName field)
          native <- typeText "" names parameters (C.binderType field)
          selector <- maybe (Left "unplanned Haskell record selector") Right
            (lookup (C.constructorId variant, C.binderId field) selectors)
          pure (selector,native)
        unless (length fields == length (nub (map fst fields))) (Left "Haskell constructor fields collide after naming")
        pure (constructor, fields)
      -- As ormolu lays out a data declaration: on one line when it fits;
      -- otherwise one constructor's fields in braces below it, or each
      -- constructor on a line of its own.
      let record nesting fields = if null fields then mempty else D.nest nesting (D.softline <> D.text "{" <> D.whenBroken (D.text " ") <>
            D.nest 2 (D.joinWith (D.text "," <> D.softline) [D.text (f ++ " :: " ++ t) | (f, t) <- fields]) <> D.softbreak <> D.text "}")
      pure [case variants of
        [] -> D.group (D.text header <> D.nest 2 (D.softline <> deriving'))
        [(constructor, fields)] -> D.group (D.text (header ++ " = " ++ constructor) <> record 2 fields <> D.nest 2 (D.softline <> deriving'))
        (first : rest) -> D.group (D.text header <> D.nest 2 (D.softline <> D.text "= " <> alternative first <>
          mconcat [D.softline <> D.text "| " <> alternative v | v <- rest] <> D.softline <> deriving'))]
      where alternative (constructor, fields) = D.group (D.text constructor <> (if null fields then mempty else
              D.nest 4 (D.softline <> D.text "{" <> D.whenBroken (D.text " ") <>
                D.nest 2 (D.joinWith (D.text "," <> D.softline) [D.text (f ++ " :: " ++ t) | (f, t) <- fields]) <> D.softbreak <> D.text "}")))
    -- GADT syntax: each constructor states the type it builds. Existential
    -- fields keep their types; values compare only through LawSpec's codecs,
    -- so Eq is derived only where no constructor is existential.
    gadtDefinition names selectors declaration = do
      name <- lookupName names (C.dataId declaration)
      let parameters = zip (C.dataParameters declaration) ["a" ++ show n | n <- [0::Int ..]]
          own = unwords (name : map snd parameters)
          wrapped text = if ' ' `elem` text then "(" ++ text ++ ")" else text
      variants <- forM (C.dataConstructors declaration) $ \variant -> do
        constructor <- lookupName names (C.constructorId variant)
        let existentials = zip (C.constructorExistentials variant) ["e" ++ show n | n <- [0::Int ..]]
            scope = parameters ++ existentials
            refine = substitute (M.fromList (C.constructorEquations variant))
        arguments <- forM parameters $ \(p, v) -> maybe (pure v) (fmap wrapped . typeText "" names scope)
          (lookup p (C.constructorEquations variant))
        fields <- forM (C.constructorFields variant ++ witnessBinders declaration variant) $ \field -> do
          fieldIdentifier (C.binderName field)
          native <- typeText "" names scope (refine (C.binderType field))
          selector <- maybe (Left "unplanned Haskell record selector") Right
            (lookup (C.constructorId variant, C.binderId field) selectors)
          pure (selector,native)
        let result = unwords (name : arguments)
        pure (D.text (constructor ++ " :: " ++ (if null fields then "" else
          "{" ++ intercalate ", " [field ++ " :: " ++ ty | (field,ty) <- fields] ++ "} -> ") ++ result))
      constructorNames <- mapM (lookupName names . C.constructorId) (C.dataConstructors declaration)
      registry <- makeRegistry declarations
      -- A determined existential can be shown through a result parameter
      -- that names it directly. Show [a] alone does not supply Show a.
      let needed = nub [parameter | variant<-C.dataConstructors declaration,
            (parameter,C.TypeVariable variable)<-C.constructorEquations variant,
            variable `elem` C.constructorExistentials variant,
            field<-C.constructorFields variant,
            Right requirements<-[equalityRequirements registry
              (substitute (M.fromList (C.constructorEquations variant)) (C.binderType field))],
            variable `elem` requirements]
          showContext = case ["P.Show "++variable | (parameter,variable)<-parameters,parameter `elem` needed] of
            [] -> ""
            constraints -> "("++intercalate ", " constraints++") => "
          existential = any (not . null . C.constructorExistentials) (C.dataConstructors declaration)
          -- A field-only existential's value has no Show instance to use:
          -- such a type shows only its constructors.
          opaque = any (not . null . freeExistentials declaration) (C.dataConstructors declaration)
          instances = [D.text ("deriving instance P.Eq (" ++ own ++ ")") | not existential] ++
            (if opaque
              then [D.text ("instance P.Show (" ++ own ++ ") where") <> D.nest 2 (D.hardline <>
                D.joinWith D.hardline [D.text ("showsPrec _ " ++ constructor ++ " {} = P.showString " ++ show constructor) | constructor <- constructorNames])]
              else [D.text ("deriving instance " ++ showContext ++ "P.Show (" ++ own ++ ")")])
      pure ((D.text ("data " ++ own ++ " where") <> D.nest 2 (D.hardline <> D.joinWith D.hardline variants)) : instances)
    lookupName names identity = maybe (Left "unplanned Haskell data name") Right (lookup identity names)

-- | A generated module: its header, extensions, the imports its code uses
-- (in ormolu's order) and its declarations, a blank line apart.
moduleText :: D.Layout -> String -> String -> [String] -> [(String, Maybe String, Maybe [String])] -> [D.Doc] -> String
moduleText layout name exports extensions candidates declarations =
  let rendered = D.render D.Compact (D.joinWith D.hardline declarations)
      imports = moduleImports rendered candidates
  in D.render layout (D.joinWith D.hardline (map D.text
      (["-- " ++ generatedHeader Nothing] ++ ["{-# LANGUAGE " ++ e ++ " #-}" | e <- sort extensions] ++
       ["", "module " ++ name ++ exports ++ " where"] ++ (if null imports then [] else "" : imports))) <>
    mconcat [D.hardline <> D.hardline <> d | d <- declarations] <> D.hardline)

-- | Import lines in ormolu's order, only those a module's code uses: each
-- is (module, alias, imported names), where an alias is a qualified import.
moduleImports :: String -> [(String, Maybe String, Maybe [String])] -> [String]
moduleImports rendered candidates = sortedImports [c | c <- candidates, used c]
  where
    used (_, Just alias, _) = (alias ++ ".") `isInfixOf` rendered
    -- import M () imports nothing; it is kept as written.
    used (_, Nothing, Just []) = True
    used (_, Nothing, Just names) = any (`elem` identifiers) (concat [takeWhile isAlphaNum n : constructorsOf n | n <- names])
    used (_, Nothing, Nothing) = True
    constructorsOf n = if n == "Scalar (..)" then words "SInteger SBool SDecimal SRational SFloat SComplex SSequence SCharacter SSymbol SScopedSymbol SAbsent SPresent SList SData SHandle" else []
    identifiers = words (map (\c -> if isAlphaNum c || c `elem` ("_'" :: String) then c else ' ') rendered)

-- | Import lines in ormolu's order: by module, an unqualified import before
-- a qualified one, Prelude last.
sortedImports :: [(String, Maybe String, Maybe [String])] -> [String]
sortedImports = map line . sortOn key . merged . nub
  where
    -- ormolu joins a module's import lists into one, its names sorted.
    merged specs = foldr add [] specs
    add (m, alias, Just names) acc
      | any (\(m', a', n') -> m' == m && a' == alias && n' /= Nothing && n' /= Just []) acc, not (null names) =
          [ if m' == m && a' == alias && n' /= Nothing then (m', a', fmap (\ns -> sort (nub (ns ++ names))) n') else e | e@(m', a', n') <- acc ]
    add (m, alias, names) acc = (m, alias, fmap sort names) : acc
    key (m, alias, _) = (m == "Prelude", m, alias /= Nothing, alias /= Nothing && alias /= Just m)
    line (m, alias, names) = "import " ++ maybe "" (const "qualified ") alias ++ m ++
      maybe "" (\a -> if a == m then "" else " as " ++ a) alias ++
      maybe "" (\ns -> " (" ++ intercalate ", " ns ++ ")") names

typeVariablesIn :: C.Type -> [C.Id]
typeVariablesIn ty = case ty of
  C.TypeVariable v -> [v]
  C.Constructor _ arguments -> concat [typeVariablesIn t | C.TypeArgument t <- arguments]
  C.Arrow a b -> typeVariablesIn a ++ typeVariablesIn b

gadtDeclaration :: C.DataDeclaration -> Bool
gadtDeclaration declaration = any (\c -> not (null (C.constructorEquations c)) || not (null (C.constructorExistentials c)))
  (C.dataConstructors declaration)

-- | The 64-bit profile unless a caller states another.
-- ref:DEC-explicit-machine-profile
emitHaskellSchema :: D.Layout -> [C.DataDeclaration] -> Either String String
emitHaskellSchema = emitHaskellSchemaWithProfile 64

-- | Constructor invariants are proved before the schema is emitted, so the
-- generated checks are the proved ones.
emitHaskellSchemaWithProfile :: Int -> D.Layout -> [C.DataDeclaration] -> Either String String
emitHaskellSchemaWithProfile bits layout declarations = do
  _ <- emitHaskellData layout declarations
  _ <- either (Left . show) Right (constructorProofContracts bits declarations)
  (schemas,contracts) <- S.dataSchemasWithContracts declarations
  callbacks <- forM contracts $ \contract -> do
    predicates <- forM (S.contractPredicates contract) $ \predicate -> do
      let fields = zip (map C.binderId (S.contractFields contract))
            ["(fields P.!! " ++ show i ++ ")" | i <- [0 :: Int ..]]
          nested = zip (nub (nestedIds predicate)) ["local" ++ show i | i <- [0 :: Int ..]]
          local identity = maybe "invalidField" id (lookup identity (fields ++ nested))
          ref ty = do
            value <- referenceExpr <$> S.typeReference (S.contractParameters contract) ty
            pure (H.call "Schema.substitute" [H.var "types",value])
          key ty
            | variable ty = Left "unresolved Haskell generic conversion target"
            | otherwise = pure (H.string (Backend.scalarTypeKey ty))
      body <- E.renderExpressionWithContext declarations (H.var "bits") "_schema"
        (H.var "symbols") ref key local
        (\_ _ -> Left "external call in constructor predicate") predicate
      pure (H.lambda ["_schema", "types", "fields", "bits", "symbols"]
        (H.call "P.Right" [H.call "LS.truth" [body]]))
    pure (H.Tuple [H.string (S.contractTag contract), H.List predicates])
  let field value = H.call "Schema.Field" [H.string (S.fieldName value), referenceExpr (S.fieldType value)]
      constructor value = H.call "Schema.Constructor" [H.string (S.constructorTag value), H.List (map field (S.fields value))]
      definition value = H.call "Schema.Definition"
        [H.string (S.typeName value), H.integer (toInteger (S.parameterCount value)), H.List (map constructor (S.constructors value))]
      indexTables = [H.Tuple [H.string (S.constructorTag c), H.List (map H.string (S.constructorIndex c))]
        | s <- schemas, c <- S.constructors s, not (null (S.constructorIndex c))]
      refinementTable = [H.Tuple [H.string (S.constructorTag c),
          H.Tuple [H.List [H.Tuple [H.integer (toInteger index), referenceExpr pattern] | (index, pattern) <- S.constructorRefinements c],
                   H.integer (toInteger (S.constructorExistentials c))]]
        | s <- schemas, c <- S.constructors s, not (null (S.constructorRefinements c)) || S.constructorExistentials c > 0]
      witnessTable = [H.Tuple [H.string (S.constructorTag c), H.List (map (H.integer . toInteger) (S.constructorWitnesses c))]
        | s <- schemas, c <- S.constructors s, not (null (S.constructorWitnesses c))]
      primitiveNames = H.List (map (H.string . primitiveName) primitives)
      expression = if not (null witnessTable) then H.call "Schema.witnessedSchema" [H.List witnessTable, unwitnessed] else unwitnessed
      unwitnessed = if not (null refinementTable)
        then H.call "Schema.createRefined" [H.List (map definition schemas), primitiveNames, H.List callbacks, H.List indexTables, H.List refinementTable]
        else if null indexTables
        then H.call "Schema.createWithContracts" [H.List (map definition schemas), primitiveNames, H.List callbacks]
        else H.call "Schema.createIndexed" [H.List (map definition schemas), primitiveNames, H.List callbacks, H.List indexTables]
      qualifiedPrelude = not (null callbacks)
  pure (moduleText layout "LawSpecDataSchema" " (schema)" []
    [("Prelude", Just "P", Nothing), ("LawSpecRuntime", Nothing, Just ["Scalar (..)"]), ("LawSpecRuntime", Just "LS", Nothing),
     ("LawSpecSchema", Just "Schema", Nothing)]
    [D.joinWith D.hardline [H.comment ["The program's types, as the runtime checks values against them."],
       H.signature "schema" [if qualifiedPrelude then "P.Either P.String Schema.Schema" else "Either String Schema.Schema"],
       H.declaration "schema" expression]])

  where
    nestedIds term = (case C.expressionNode term of
      C.Let binder _ _ -> [C.binderId binder]
      C.AllElements _ binder _ -> [C.binderId binder]
      C.AllPayloads _ predicates -> map (C.binderId . fst) predicates
      C.Match _ branches -> concatMap (map C.binderId . C.caseBinders) branches
      _ -> []) ++ concatMap nestedIds (C.children term)
    variable (C.TypeVariable _) = True
    variable (C.Constructor _ args) = any (\arg -> case arg of C.TypeArgument ty -> variable ty; _ -> False) args
    variable (C.Arrow a b) = variable a || variable b

-- | Record selectors occupy one value namespace across the generated module.
-- Constructor-qualified names can still collide at concatenation boundaries.
selectorsFor :: Names -> [C.DataDeclaration] -> Either String [((C.Id,C.Id),String)]
selectorsFor names declarations = do
  candidates <- sequence
    [do constructor <- maybe (Left "unplanned Haskell constructor") Right
          (lookup (C.constructorId variant) names)
        let prefix = case constructor of c:cs -> toLower c:cs; [] -> ""
        pure ((C.constructorId variant, C.binderId field), prefix ++ capitalize (C.binderName field))
    | declaration <- declarations, variant <- C.dataConstructors declaration,
      field <- C.constructorFields variant ++ witnessBinders declaration variant]
  let duplicated name = length (filter ((== name) . snd) candidates) > 1
      unique (constructor,field) name = if duplicated name
        then "field_" ++ concatMap (\c -> showHex (ord c) "_")
          (C.idText constructor ++ "\0" ++ C.idText field)
        else name
      result = [(identity,unique identity name) | (identity,name) <- candidates]
  unless (length result == length (nub (map snd result)))
    (Left "conflicting Haskell field identities")
  pure result

-- | A field-only existential's type travels as a Text witness field, after the
-- declared fields.
witnessBinders :: C.DataDeclaration -> C.DataConstructor -> [C.Binder]
witnessBinders declaration variant =
  [C.Binder (C.Id ("witness#" ++ show k)) (S.witnessFieldName count k) (C.Constructor "Text" []) | k <- [0 .. count - 1]]
  where count = length (freeExistentials declaration variant)

-- | A type reference as an expression.
referenceExpr :: S.TypeRef -> H.Expr
referenceExpr (S.Parameter index) = H.call "Schema.Parameter" [H.integer (toInteger index)]
referenceExpr (S.Named name arguments) = H.call "Schema.Named" [H.string name, H.List (map referenceExpr arguments)]

codecName :: String -> String
codecName [] = "dataCodec"
codecName (c:cs) = toLower c : cs ++ "Codec"

-- | A codec as an expression: the program's own types' codecs come from
-- LawSpecDataCodecs, the built-in ones from LawSpecCodecs and
-- LawSpecCollectionCodecs.
codecExpressionWith :: Maybe H.Expr -> String -> String -> String -> Names -> [(C.Id,String)] -> C.Type -> Either String H.Expr
codecExpressionWith context schema bits scope names parameters ty = case ty of
  C.TypeVariable variable -> maybe (Left "unbound Haskell codec parameter") (Right . H.var) (lookup variable parameters)
  C.Constructor name arguments | Just short <- collectionContainer name -> do
    children <- mapM argument arguments
    values <- mapM (codecExpressionWith context schema bits scope names parameters) children
    let scope' = maybe (H.var "P.Nothing") id context
        call' function extra = H.call function (extra ++ [scope', H.var schema, H.var bits] ++ values)
    pure $ case short of
      "Set" -> call' "Collections.setCodecWith" []
      "KeyVal" -> call' "Collections.keyValCodecWith" []
      _ -> call' "Collections.sequenceCodecWith" [H.string short]
  C.Constructor name arguments -> do
    children <- mapM argument arguments
    values <- mapM (codecExpressionWith context schema bits scope names parameters) children
    case lookup (C.Id name) names of
      Just native -> pure (contextual (scope ++ codecName native) values)
      Nothing -> case lookup name [("List","listCodec"),("Maybe","maybeCodec"),
          ("Either","eitherCodec"),("Nullable","nullableCodec"),("Optional","optionalCodec")] of
        Just constructor -> pure (contextual ("Codec." ++ constructor) values)
        Nothing | not (null children) -> Left "unsupported Haskell codec application"
                | isInteger name -> pure (invoke "Codec.integerCodec" [H.string name])
                | name `elem` ["Char","CodePoint"] -> pure (invoke "Codec.characterCodec" [H.string name])
                | otherwise -> case lookup name helpers of
                    Just helper -> pure (invoke ("Codec." ++ helper) [])
                    Nothing -> Left ("no Haskell scalar codec for " ++ name)
  _ -> Left "unsupported Haskell codec type"
  where
    argument (C.TypeArgument value) = Right value
    argument _ = Left "indexed Haskell codec is not supported"
    invoke name arguments = H.call name (map H.var [schema,bits] ++ arguments)
    contextual name arguments = case context of
      Nothing -> invoke name arguments
      Just value -> H.call (name ++ "With") (value : map H.var [schema,bits] ++ arguments)
    helpers = [("Bool","boolCodec"),("Decimal","decimalCodec"),("Rational","rationalCodec"),
      ("Float32","float32Codec"),("Float64","float64Codec"),("Complex64","complex64Codec"),
      ("Complex128","complex128Codec"),("CodeUnit16","codeUnitCodec"),("Text","textCodec"),
      ("Bytes","bytesCodec"),("CodePointText","codePointTextCodec"),("Utf16Text","utf16TextCodec"),
      ("Symbol","symbolCodec"),("Unit","unitCodec"),("Null","nullCodec"),("Undefined","undefinedCodec")]

-- | Codec text for one-line uses.
haskellCodec :: [C.DataDeclaration] -> C.Type -> Either String String
haskellCodec declarations ty = D.render D.Compact <$> haskellCodecDoc declarations "schema" "bits" ty

-- | Every value crossing the adapter boundary goes through a codec that checks
-- it against its declared domain. ref:DEC-portable-exact-arithmetic
haskellCodecDoc :: [C.DataDeclaration] -> String -> String -> C.Type -> Either String D.Doc
haskellCodecDoc declarations schema bits ty = H.expression <$> haskellCodecExpr Nothing declarations schema bits ty

-- | As haskellCodecDoc, where the schema comes from the caller's scope.
haskellCodecDocWithContext :: H.Expr -> [C.DataDeclaration] -> String -> String -> C.Type -> Either String H.Expr
haskellCodecDocWithContext context = haskellCodecExpr (Just context)

haskellCodecExpr :: Maybe H.Expr -> [C.DataDeclaration] -> String -> String -> C.Type -> Either String H.Expr
haskellCodecExpr context = haskellCodecDocIn context "Codecs."

haskellCodecDocIn :: Maybe H.Expr -> String -> [C.DataDeclaration] -> String -> String -> C.Type -> Either String H.Expr
haskellCodecDocIn context scope declarations =
  -- The registry and the names depend only on the declarations, so a caller
  -- that applies this to them once shares them across every codec it makes.
  let prepared = (,) <$> makeRegistry declarations <*> namesFor declarations
  in \schema bits ty -> do
    (registry, names) <- prepared
    checkType registry ty
    codecExpressionWith context schema bits scope names [] ty

-- | Codecs for generated types live in one generated module.
emitHaskellCodecs :: D.Layout -> [C.DataDeclaration] -> Either String String
emitHaskellCodecs layout declarations =
  emitHaskellCodecsWithRepresentations layout declarations "LawSpecDataCodecs" [] [] []

-- Codec identities remain canonical even when their Haskell representations
-- come from application modules. Field mappings use record syntax in both
-- directions, so native declaration order cannot change the logical payload.
emitHaskellCodecsWithRepresentations
  :: D.Layout -> [C.DataDeclaration] -> String -> [String]
  -> [(C.Id, String)] -> [(C.Id, (String, [String]))]
  -> Either String String
emitHaskellCodecsWithRepresentations layout declarations owner imports representations constructors =
  emitHaskellCodecsWithHooks layout declarations owner imports representations constructors []

emitHaskellCodecsWithHooks
  :: D.Layout -> [C.DataDeclaration] -> String -> [String]
  -> [(C.Id, String)] -> [(C.Id, (String, [String]))] -> [(C.Id, (String, String))]
  -> Either String String
emitHaskellCodecsWithHooks layout declarations owner imports representations constructors hooks =
  emitHaskellCodecsWithLayouts layout declarations owner imports representations constructors hooks []

emitHaskellCodecsWithLayouts
  :: D.Layout -> [C.DataDeclaration] -> String -> [String]
  -> [(C.Id, String)] -> [(C.Id, (String, [String]))] -> [(C.Id, (String, String))]
  -> [(C.Id, ResolvedConstructorBinding)] -> Either String String
emitHaskellCodecsWithLayouts layout declarations owner imports representations constructors hooks layouts = do
  _ <- emitHaskellData layout declarations
  names <- namesFor declarations
  let graph = Identity.dependencyGraph declarations []
      cachedDefinition declaration =
        let reached = declaration : Identity.reachableData graph (Identity.closure graph (Identity.referencesOf graph declaration))
            selected = [identity | value <- reached, identity <- C.dataId value : map C.constructorId (C.dataConstructors value)]
            relevant entries = [entry | entry@(identity,_) <- entries, identity `elem` selected]
            context = (owner,relevant representations,relevant constructors,relevant hooks,relevant layouts)
        in memoized codecDocumentTable
          (Identity.fullKey graph ("public-haskell-codec:" ++ show context ++ EmissionContext.declarationContext graph declarations names declaration) declaration)
          (definition names declaration)
  definitions' <- mapM cachedDefinition [d | d <- declarations, collectionContainer (C.idText (C.dataId d)) == Nothing]
  dynamic <- if owner == "LawSpecDataCodecs" && any existentialDeclaration declarations
    then (: []) <$> dynamicDispatch names else pure []
  let gadts = any gadtDeclaration declarations
  pure (moduleText layout owner "" (["EmptyCase"] ++ (if gadts then ["GADTs", "ScopedTypeVariables"] else []))
    ([("Prelude", Just "P", Nothing), ("LawSpecRuntime", Just "LS", Nothing), ("LawSpecSchema", Just "Schema", Nothing),
      ("LawSpecCodecs", Just "Codec", Nothing), ("LawSpecData", Just "Data", Nothing),
      ("LawSpecCollectionCodecs", Just "Collections", Nothing), ("Data.Set", Just "Set", Nothing),
      ("Data.Map.Strict", Just "Map", Nothing), ("Data.Sequence", Just "Seq", Nothing),
      ("Unsafe.Coerce", Nothing, Just ["unsafeCoerce"]), ("GHC.Exts", Nothing, Just ["Any"]),
      ("Data.Int", Just "I", Nothing), ("Data.Word", Just "W", Nothing), ("Data.Text", Just "T", Nothing),
      ("Data.ByteString", Just "B", Nothing), ("Data.Complex", Just "C", Nothing),
      ("LawSpecDataCodecs", Just "Canonical", Nothing)] ++
     [case words i of
        [m, "as", alias] -> (m, Just alias, Nothing)
        _ -> (i, Just i, Nothing)
     | i <- imports])
    (definitions' ++ dynamic))
  where
    sdata tag fields = H.call "LS.SData" [H.string tag, H.List fields]
    pattern' e = D.render D.Compact (H.expression e)
    -- A clause: name pattern = expression.
    clause name matched body = H.declaration (name ++ " (" ++ matched ++ ")") body
    contextual tag method converter value = H.call "Codec.context" [H.string tag, H.call ("Codec." ++ method) [converter, value]]
    layoutVariant names codecs declaration variant mapped bound tree = do
      (native,selectors)<-maybe (Left "Haskell native layout requires a constructor mapping") Right mapped
      unless (length selectors==length (resolvedFields bound))
        (Left "Haskell native layout selector count does not match its checked leaves")
      let fields=map fst (resolvedFields bound)
          paths=maybe [] id (resolvedFieldPaths bound)
          values=[H.var ("value"++show index) | index<-[0::Int ..length fields-1]]
          converted=[H.var ("field"++show index) | index<-[0::Int ..length fields-1]]
          tag=C.idText (C.constructorId variant)
          construct entries=H.Record native (zip selectors entries)
          rawRecord _ constructor children=Right (sdata (C.idText (C.constructorId constructor)) children)
      bridges<-mapM (codecExpressionWith (Just (H.var "symbols")) "schema" "bits"
        (if owner/="LawSpecDataCodecs" && lookup (C.dataId declaration) representations==Nothing then "Canonical." else "")
        names codecs . C.binderType) fields
      patterns<-foldNativeLayoutM (Right . (values !!)) rawRecord tree
      packed<-foldNativeLayoutM (Right . (converted !!)) rawRecord tree
      let bindings method=[H.Bind ("field"++show index) (contextual (tag++"."++intercalate "." path) method bridge value) |
              (index,((bridge,value),path))<-zip [0::Int ..] (zip (zip bridges values) paths)]
      -- codecWith validates recursively before decode and after encode, as it
      -- does for the ordinary flat codecs. Packing introduces no unchecked exit.
      pure (clause "decodeValue" (pattern' (sdata tag patterns)) (H.Do (bindings "decode" ++ [H.Run (H.call "P.pure" [construct converted])])),
        clause "encodeValue" (pattern' (construct values)) (H.Do (bindings "encode" ++ [H.Run (H.call "P.pure" [sdata tag packed])])))
    existentialDeclaration declaration = any (not . null . C.constructorExistentials) (C.dataConstructors declaration)
    -- The native codec of any instantiated type, built at run time: a GADT
    -- case's existential fields learn their types from the value's own type.
    dynamicDispatch names = do
      let variable i = C.TypeArgument (C.TypeVariable (C.Id ("dynamic" ++ show i)))
          children = [(C.Id ("dynamic" ++ show i), "(dynamicCodecWith symbols schema bits x" ++ show i ++ ")") | i <- [0 :: Int .. 1]]
          arm key arity ty = do
            codec <- codecExpressionWith (Just (H.var "symbols")) "schema" "bits" "" names children ty
            -- A scalar codec is fixed to its native type before it loses it.
            annotated <- if arity == (0 :: Int)
              then H.Typed codec . ("Codec.Codec " ++) <$>
                typeText (if any ((== C.Id key) . C.dataId) declarations then "Data." else "") names [] ty
              else pure codec
            pure ("Schema.Named " ++ H.renderString key ++ " [" ++ intercalate ", " ["x" ++ show i | i <- [0 .. arity - 1]] ++ "]",
              H.call "unsafeCoerce" [annotated])
      dataArms <- mapM (\d -> let arity = length (C.dataParameters d) in
        arm (C.idText (C.dataId d)) arity (C.Constructor (C.idText (C.dataId d)) [variable i | i <- [0 .. arity - 1]])) declarations
      structural <- mapM (\(name, arity) -> arm name arity (C.Constructor name [variable i | i <- [0 .. arity - 1]]))
        [("List", 1), ("Maybe", 1), ("Either", 2), ("Nullable", 1), ("Optional", 1)]
      let scalars = concat [either (const []) pure (arm (primitiveName p) 0 (C.Constructor (primitiveName p) [])) | p <- primitives]
      pure (D.joinWith D.hardline
        [ H.signature "dynamicCodecWith" ["P.Maybe LS.SymbolContext", "Schema.Schema", "P.Int", "Schema.TypeRef", "Codec.Codec Any"]
        , H.declaration "dynamicCodecWith symbols schema bits typeRef" (H.Case (H.var "typeRef")
            (dataArms ++ structural ++ scalars ++
              [("_", H.call "unsafeCoerce" [H.call "Codec.codecWith" (map H.var ["symbols", "schema", "bits", "typeRef", "P.Right", "P.Right"])])])) ])
    definition names declaration = do
      native <- maybe (Left "unplanned Haskell codec type") Right (lookup (C.dataId declaration) names)
      let parameters = zip (C.dataParameters declaration) ["a" ++ show n | n <- [0::Int ..]]
          codecs = zip (C.dataParameters declaration) ["element" ++ show n | n <- [0::Int ..]]
          result = application (maybe ("Data." ++ native) id
            (lookup (C.dataId declaration) representations)) (map snd parameters)
          types = ["Schema.Schema", "P.Int"] ++ ["Codec.Codec " ++ name | (_,name) <- parameters] ++ ["Codec.Codec " ++ result]
          gadt = gadtDeclaration declaration
          -- GADT matches need the scoped result type in encodeValue.
          forall' = if gadt && not (null parameters) then "forall " ++ unwords (map snd parameters) ++ "." else ""
          withName = codecName native ++ "With"
          typeRef = H.call "Schema.Named" [H.string (C.idText (C.dataId declaration)),
            H.List [H.call "Codec.reference" [H.var value] | (_,value) <- codecs]]
          header = unwords (withName : "symbols" : "schema" : "bits" : map snd codecs)
          expression = H.call "Codec.codecWith" [H.var "symbols", H.var "schema", H.var "bits",
            if gadt then H.var "typeReference" else typeRef, H.var "decodeValue", H.var "encodeValue"]
      variants <- forM (C.dataConstructors declaration) $ \variant -> do
        constructor <- maybe (Left "unplanned Haskell codec constructor") Right
          (lookup (C.constructorId variant) names)
        let mapped = lookup (C.constructorId variant) constructors
        case lookup (C.constructorId variant) layouts of
          Just bound | Just tree<-resolvedFieldLayout bound->layoutVariant names codecs declaration variant mapped bound tree
          _->do
            case mapped of
              Just (_, selectors) -> unless (length selectors == length (C.constructorFields variant))
                (Left ("Haskell native field mapping arity mismatch: " ++ C.idText (C.constructorId variant)))
              Nothing -> pure ()
            let existentialField field = any (`elem` C.constructorExistentials variant) (typeVariablesIn (C.binderType field))
                -- The constructor's result fixes these parameters. Use the same
                -- refined field types as its native declaration in both directions.
                refinedFields = [field { C.binderType = substitute (M.fromList (C.constructorEquations variant)) (C.binderType field) }
                  | field <- C.constructorFields variant]
                witnesses = witnessBinders declaration variant
                declaredCount = length (C.constructorFields variant)
                -- @KEYS@: the value's witness keys, from its data or native fields.
                keysOf method = H.List (if method == "encode"
                  then [H.call "T.unpack" [H.var ("value" ++ show (declaredCount + k))] | k <- [0 .. length witnesses - 1]]
                  else [H.call "Schema.witnessText" [H.var ("value" ++ show (declaredCount + k))] | k <- [0 .. length witnesses - 1]])
            fields <- mapM (\(position, field) -> if existentialField field
              -- An existential field's type comes from the value's own type, or
              -- from its witnesses.
              then pure (\method -> H.call "dynamicCodecWith" [H.var "symbols", H.var "schema", H.var "bits",
                if null witnesses
                  then H.call "Schema.fieldType" [H.var "schema", H.var "typeReference", H.string (C.idText (C.constructorId variant)), H.integer (toInteger position)]
                  else H.call "Schema.fieldTypeAt" [H.var "schema", H.var "typeReference", H.string (C.idText (C.constructorId variant)), H.integer (toInteger position), keysOf method]])
              else const <$> codecExpressionWith (Just (H.var "symbols")) "schema" "bits"
              (if owner /= "LawSpecDataCodecs" && lookup (C.dataId declaration) representations == Nothing then "Canonical." else "") names codecs (C.binderType field))
              (zip [0 :: Int ..] (refinedFields ++ witnesses))
            let tag = C.idText (C.constructorId variant)
                values = ["value" ++ show n | n <- [0::Int .. length fields - 1]]
                converted = ["field" ++ show n | n <- [0::Int .. length fields - 1]]
                -- Existential values cross as Any; the schema checked their types.
                coerced binder v = if existentialField binder then H.call "unsafeCoerce" [H.var v] else H.var v
                bindings method =
                  [ H.Bind field' (contextual (tag ++ "." ++ C.binderName binder) method (converter' method)
                      (if method == "encode" then coerced binder value else H.var value))
                  | (binder,converter',value,field') <- zip4 (refinedFields ++ witnesses) fields values converted ]
                construct arguments = case mapped of
                  Nothing -> H.call ("Data." ++ constructor) arguments
                  Just (name, []) -> H.var name
                  Just (name, selectors) -> H.Record name (zip selectors arguments)
                -- A refined case builds its refined type; the schema has already
                -- checked it is a value of this one.
                decodeBody = bindings "decode" ++
                  [H.Run (H.call "P.pure" [(if gadt then \d -> H.call "unsafeCoerce" [d] else id)
                    (construct [coerced binder value | (binder, value) <- zip (refinedFields ++ witnesses) converted])])]
                encodeBody = bindings "encode" ++ [H.Run (H.call "P.pure" [sdata tag (map H.var converted)])]
            pure (clause "decodeValue" (pattern' (sdata tag (map H.var values))) (H.Do decodeBody),
              clause "encodeValue" (pattern' (construct (map H.var values))) (H.Do encodeBody))
      let decoders = map fst variants ++ [H.declaration "decodeValue _" (H.call "P.Left" [H.string "invalid checked constructor"])]
          encoders = if null variants then [H.declaration "encodeValue value" (H.var "case value of {}")] else map snd variants
      let tag = C.idText (C.dataId declaration)
          bound = lookup (C.dataId declaration) representations /= Nothing
      implementations <- case lookup (C.dataId declaration) hooks of
        -- A handle crosses as itself; a bound native value is wrapped in a
        -- handle (and unwrapped at its own type).
        _ | C.dataHandle declaration -> pure
          [H.declaration "decodeValue (LS.SHandle _ value)" (H.call "P.pure" [if bound then H.call "LS.fromHandle" [H.var "value"] else H.var "value"]),
           H.declaration "decodeValue _" (H.call "P.Left" [H.string "invalid checked handle"]),
           H.declaration "encodeValue value" (H.call "P.pure" [H.call "LS.SHandle" [H.string tag, if bound then H.call "LS.wrapHandle" [H.var "value"] else H.var "value"]])]
        Nothing -> pure ([H.declaration "typeReference" typeRef | gadt] ++
          [H.signature "encodeValue" [result, "P.Either P.String LS.Scalar"] | gadt] ++ decoders ++ encoders)
        Just (toNative,fromNative) -> do
          -- Type parameters stay opaque to the hook. Their checked logical
          -- values cross the supplied directional child converters.
          let logicalChild element = H.call "Codec.codecWith"
                [H.var "symbols", H.var "schema", H.var "bits", H.call "Codec.reference" [H.var element], H.var "P.Right", H.var "P.Right"]
              canonical = H.call ("Canonical." ++ codecName native ++ "With")
                ([H.var "symbols", H.var "schema", H.var "bits"] ++ map (logicalChild . snd) codecs)
              converters method = [H.lambda ["child"] (H.call "P.either" [H.var "P.error", H.var "P.id",
                H.call ("Codec." ++ method) [H.var element, H.var "child"]]) | (_,element) <- codecs]
              context direction statements = H.dollarIn "P." (H.call "Codec.context"
                [H.string ("native codec " ++ C.idText (C.dataId declaration) ++ " " ++ direction)]) (H.Do statements)
          pure [H.declaration "logicalCodec" canonical,
            H.declaration "decodeValue value" (context "toNative"
              [H.Bind "canonical" (H.call "Codec.decode" [H.var "logicalCodec", H.var "value"]),
               H.Run (H.call toNative (H.var "canonical" : converters "decode"))]),
            H.declaration "encodeValue value" (context "fromNative"
              [H.Bind "canonical" (H.call fromNative (H.var "value" : converters "encode")),
               H.Run (H.call "Codec.encode" [H.var "logicalCodec", H.var "canonical"])])]
      pure (D.joinWith D.hardline
        [ H.signature (codecName native) types
        , H.declaration (codecName native) (H.call withName [H.var "P.Nothing"]) ]
        <> D.hardline <> D.hardline <>
        D.joinWith D.hardline
        [ D.group (D.text (withName ++ " ::") <> D.nest 2 ((if null forall' then mempty else D.softline <> D.text forall') <> D.softline <>
            D.joinWith (D.text " ->" <> D.softline) (map D.text ("P.Maybe LS.SymbolContext" : types))))
        , H.declaration header expression <> D.nest 2 (D.hardline <> D.text "where" <>
            D.nest 2 (D.hardline <> D.joinWith D.hardline implementations)) ])
