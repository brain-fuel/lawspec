-- | Native JS classes and TS generic unions rendered from checked Core.
module LawSpec.WebData (emitWebData, emitWebDataWithProfile, webDataType, webTypeReference, webDataTypeOf, webDataTypeOfWith, webDataTypeDoc, webDataTypeDocWith, webTypeReferenceDoc, requiresSchema, testStrategies, printWith) where

import System.IO.Unsafe (unsafePerformIO)
import LawSpec.Memo (Table, newPersistentTable, memoized)
import qualified LawSpec.Dependencies as Identity
import qualified LawSpec.Typed.EmissionContext as EmissionContext
import Control.Monad (unless, forM)
import Data.List (intercalate, isPrefixOf)
import qualified LawSpec.Backend as Backend
import qualified LawSpec.Core as C
import qualified LawSpec.Core.Schema as S
import LawSpec.Core.Types (makeRegistry, freeExistentials)
import LawSpec.Common (Artifact(..))
import LawSpec.Scalar
import LawSpec.RuntimeSources (runtimeSource)
import qualified LawSpec.Code.Doc as D

import LawSpec.WebTypes
import LawSpec.DataNames (isProduct, nativeConstructorFieldType)
import LawSpec.Core.Total (constructorProofContracts)
import qualified LawSpec.WebExpr as X
import qualified LawSpec.Code.ECMAScript as E
import LawSpec.WebModule (linkComment)
import LawSpec.SourceLink (sourceLink)

nativeDocumentTable :: Table (Either String [E.Stmt])
nativeDocumentTable = unsafePerformIO (newPersistentTable "public-web-data" (4 * 1024 * 1024) (length . show))
{-# NOINLINE nativeDocumentTable #-}

-- | Target imports and a known TypeScript signature slot are substituted. Runtime
-- expressions and literals stay opaque; no whitespace rewriting is performed.
replace :: String -> String -> String -> String
replace _ _ [] = []
replace old new source
  | old `isPrefixOf` source = new ++ replace old new (drop (length old) source)
  | c:rest <- source = c : replace old new rest

-- | The 64-bit profile unless a caller states another.
-- ref:DEC-explicit-machine-profile
emitWebData :: Bool -> D.Layout -> [C.DataDeclaration] -> Either String [Artifact]
emitWebData ts = emitWebDataWithProfile ts 64

-- | One emitter for JavaScript and TypeScript, so the two targets' data have the
-- same shapes and differ only in type annotations.
emitWebDataWithProfile :: Bool -> Int -> D.Layout -> [C.DataDeclaration] -> Either String [Artifact]
emitWebDataWithProfile ts bits layout declarations = do
  _ <- makeRegistry declarations
  _ <- either (Left . show) Right (constructorProofContracts bits declarations)
  names <- namesFor declarations
  (schemas,contracts) <- S.dataSchemasWithContracts declarations
  let available = ["fieldPredicate" ++ show index | index <- [1 :: Int ..],
        "fieldPredicate" ++ show index `notElem` map snd names]
      entries = zip available [(contract,predicate) | contract <- contracts,
        predicate <- S.contractPredicates contract]
      bindings = [(S.contractTag contract,name) | (name,(contract,_)) <- entries]
  callbacks <- forM entries $ \(name,(contract,predicate)) -> do
    let fields = zip (map C.binderId (S.contractFields contract))
          ["_fields[" ++ show i ++ "]" | i <- [0 :: Int ..]]
        local identity = maybe "_invalid_field" id (lookup identity fields)
        ref ty = do
          value <- reference <$> S.typeReference (S.contractParameters contract) ty
          pure (if variable ty then E.call "schema.substitute" [value,E.Ident "_types"] else value)
        typeKey ty | variable ty = E.call "schema.typeKey" . pure <$> ref ty
                   | otherwise = pure (E.Str (Backend.scalarTypeKey ty))
        parameter (n,ty) = (E.param n) { E.paramType = if ts then Just ty else Nothing }
    body <- X.renderExpressionWithContext ts declarations (E.Ident "bits") ref typeKey local
      (\_ _ -> Left "external call in constructor predicate") predicate
    pure (E.FunctionDecl False False name []
      (map parameter [("_lawspec_schema",E.TRef "schema.Schema" []),("_types",E.TRef "ReadonlyArray" [E.TRef "schema.Named" []]),
        ("_fields",E.TRef "ReadonlyArray" [E.TKeyword "unknown"]),("bits",E.TKeyword "number"),
        ("symbols",E.TRef "Map" [E.TKeyword "string", E.TKeyword "symbol"])]) Nothing
      [E.ret (if ts then E.As body (E.TKeyword "boolean") else body)])
  -- A handle has no class: its values are the adapters' own objects.
  let graph = Identity.dependencyGraphWithBits bits declarations []
      cachedDefinition declaration = memoized nativeDocumentTable
        (Identity.fullKey graph ("public-web-data:" ++ show ts ++ EmissionContext.declarationContext graph declarations names declaration) declaration)
        (definition (EmissionContext.selectedDeclarationNames graph declarations names declaration) declaration)
  classes <- concat <$> mapM cachedDefinition [d | d <- declarations, collectionContainer (C.idText (C.dataId d)) == Nothing,
    not (C.dataHandle d)]
  metadata <- mapM (definitionSchema names bindings) schemas
  let extension = if ts then "ts" else "mjs"
      importExtension = if ts then "js" else "mjs"
      header = [ E.Comment ["// Generated by LawSpec. Do not edit."]
               , E.ImportDecl False (E.ImportNamespace "ls") ("./lawspec_runtime." ++ importExtension)
               , E.ImportDecl False (E.ImportNamespace "schema") ("./lawspec_schema." ++ importExtension) ]
      factory = E.FunctionDecl True False "makeSchema" [] [] Nothing
        (concatMap (\c -> [c, E.Blank]) callbacks ++
         [E.ret (E.new' "schema.Schema"
          [E.Array metadata, E.Array (map (E.Str . primitiveName) primitives),
           E.Object [E.Prop (E.KName k) (E.Ident v) | (k, v) <- [("absent","Absent"),("present","Present"),("left","Left"),("right","Right"),("presence","Presence")]]])])
      source = header ++ concatMap (\stmt -> [E.Blank, stmt]) (builtins ++ classes ++ [factory])
      typedRuntime = if ts then replace "predicates = []"
        "predicates: FieldPredicate[] = []" $
        replace "    indices = [],\n    refinements = [],"
          "    indices: ReadonlyArray<string> = [],\n    refinements: ReadonlyArray<readonly [number, Named | Parameter]> = []," $
        replace "    witnesses = [],\n"
          "    witnesses: ReadonlyArray<number> = [],\n" $
        replace "constructor(name, args = [])"
          "constructor(name: string, args: ReadonlyArray<Named | Parameter> = [])" (runtimeSource "web-schema")
        else runtimeSource "web-schema"
      runtime = (if ts then unlines ["// @ts-nocheck", "export type FieldPredicate = (",
          "  schema: Schema,", "  types: ReadonlyArray<Named>,",
          "  fields: ReadonlyArray<unknown>,", "  bits: number,",
          "  symbols: Map<string, symbol>,", ") => boolean;", ""] else "") ++
        replace "./lawspec_runtime.mjs" ("./lawspec_runtime." ++ importExtension) typedRuntime
  pure [Artifact ("src/lawspec_data." ++ extension) (printWith layout ts source) "generated" "source",
        Artifact ("src/lawspec_schema." ++ extension) runtime "generated" "source"]
  where
    handles = handleTypes declarations
    variable (C.TypeVariable _) = True
    variable (C.Constructor _ args) = any (\arg -> case arg of C.TypeArgument ty -> variable ty; _ -> False) args
    variable (C.Arrow a b) = variable a || variable b
    alias name parameters variants = if ts
      then E.TypeAlias True name parameters (E.TUnion variants)
      else E.Comment (["/**"] ++
        [" * @template " ++ intercalate ", " parameters | not (null parameters)] ++
        [" * @typedef {" ++ intercalate " | " (map E.printType variants) ++ "} " ++ name, " */"])
    nativeClass name parameters fields =
      [E.Comment ["/** @template " ++ intercalate ", " parameters ++ " */"] | not ts, not (null parameters)] ++
      [E.ClassDecl True name (if ts then parameters else []) Nothing []
        ([E.Field ["declare", "private", "readonly"] "_lawspecBrand" (Just (E.TKeyword "void")) Nothing | ts] ++
         [E.Field (["readonly" | ts]) (key field) (if ts then Just ty else Nothing) Nothing | (field,ty) <- fields] ++
         [E.MemberBlank | not (null fields) || ts] ++
         [E.Method False False "method" "constructor"
           [(E.param ("value" ++ show i)) { E.paramType = if ts then Just ty else Nothing } | (i,(_,ty)) <- zip [0::Int ..] fields] Nothing
           ([E.ExprStmt (E.Assign "=" (E.member E.This field) (E.Ident ("value" ++ show i))) | (i,(field,_)) <- zip [0::Int ..] fields] ++
            [E.ExprStmt (E.call "Object.freeze" [E.This])])])]
    key name = if name `elem` ["constructor","__proto__"] then "[" ++ q name ++ "]" else name
    builtins =
      [alias "Maybe" ["T"] [E.TRef "Absent" [E.TRef "T" []], E.TRef "Present" [E.TRef "T" []]]] ++
      nativeClass "Absent" ["T"] [] ++ nativeClass "Present" ["T"] [("value",E.TRef "T" [])] ++
      [alias "Either" ["L","R"] [E.TRef "Left" [E.TRef "L" [], E.TRef "R" []], E.TRef "Right" [E.TRef "L" [], E.TRef "R" []]]] ++
      nativeClass "Left" ["L","R"] [("value",E.TRef "L" [])] ++
      nativeClass "Right" ["L","R"] [("value",E.TRef "R" [])] ++
      [E.ClassDecl True "Presence" ["T" | ts] (Just (E.Ident "ls" `E.member` "Presence")) []
        ([E.Field ["declare", "readonly"] "value" (Just (E.TUnion [E.TRef "T" [], E.TKeyword "undefined"])) Nothing | ts] ++
         [E.MemberBlank | ts] ++
         [E.Method False False "method" "constructor"
           (if ts then [E.typedParam "kind" (E.TUnion [E.TLiteral (E.Str "Nullable"), E.TLiteral (E.Str "Optional")]),
                        E.typedParam "present" (E.TKeyword "boolean"), E.typedParam "value?" (E.TRef "T" [])]
            else map E.param ["kind", "present", "value"]) Nothing
           [E.ExprStmt (E.Call (E.Ident "super") [] (map E.Ident ["kind", "present", "value"]) False)]])]
    definition names declaration = do
      name <- lookupName names (C.dataId declaration)
      let parameters = zip (C.dataParameters declaration)
            [candidate | n <- [0::Int ..], let candidate = "T" ++ show n, candidate `notElem` map snd names]
          args = map snd parameters
      variants <- forM (C.dataConstructors declaration) $ \constructor -> do
        native <- lookupName names (C.constructorId constructor)
        -- A GADT case is generic in the parameters it leaves open and in its
        -- existentials; the union admits it only where its refinements hold.
        let equations = C.constructorEquations constructor
            existentials = zip (C.constructorExistentials constructor)
              [candidate | n <- [0::Int ..], let candidate = "E" ++ show n, candidate `notElem` map snd names]
            -- A field-only existential is unknown statically; its witness
            -- names the type.
            free = freeExistentials declaration constructor
            scope = parameters ++ [(e, if e `elem` free then "unknown" else v) | (e, v) <- existentials]
            open = [v | (p, v) <- parameters, p `notElem` map fst equations] ++ [v | (e, v) <- existentials, e `notElem` free]
            -- A product class is also the public type, so it must retain the
            -- declaration's parameters even when its constructor fixes one.
            classArgs = if ts && not (null equations) && not (isProduct declaration) then open else args
        fields <- forM (C.constructorFields constructor) $ \field -> do
          identifier False (C.binderName field)
          unless (C.binderName field /= "_lawspecBrand") (Left "reserved TypeScript data field: _lawspecBrand")
          ty <- typeDocWith handles "" names scope (nativeConstructorFieldType declaration constructor (C.binderType field))
          pure (C.binderName field,ty)
        -- Each field-only existential's type travels as a witness string.
        let fields' = fields ++ [(S.witnessFieldName (length free) k, E.TKeyword "string") | k <- [0 .. length free - 1]]
        member <- if not ts || null equations then pure (application native [E.TRef a [] | a <- classArgs]) else do
          patterns <- mapM (\(p, ty) -> typeDocWith handles "" names [(e, "infer " ++ v) | (e, v) <- existentials] ty >>= \pattern ->
            pure (maybe "never" id (lookup p parameters), E.printType pattern)) equations
          pure (E.TRaw ("([" ++ intercalate ", " (map fst patterns) ++ "] extends [" ++ intercalate ", " (map snd patterns) ++
            "] ? " ++ E.printType (application native [E.TRef a [] | a <- classArgs]) ++ " : never)"))
        pure (member,linkComment (name ++ (if isProduct declaration then "" else "." ++ C.constructorName constructor)) (sourceLink (C.dataOrigin declaration)) : nativeClass native classArgs fields')
      -- A product's class is the type itself; only sums need a union alias.
      pure ([stmt | not (isProduct declaration), stmt <- [linkComment name (sourceLink (C.dataOrigin declaration)),
               alias name args (if null variants then [E.TKeyword "never"] else map fst variants)]] ++ concatMap snd variants)
    -- Optional trailing arguments up to the last one that is needed.
    trimmed values needed = take (length needed - length (takeWhile not (reverse needed))) values
    definitionSchema names bindings schema = do
      variants <- forM (S.constructors schema) $ \constructor -> do
        native <- if collectionContainer (S.typeName schema) /= Nothing then pure "null"
          else lookupName names (C.Id (S.constructorTag constructor))
        pure (E.new' "schema.Constructor"
          ([E.Str (S.constructorTag constructor),
           E.Array [E.new' "schema.Field" [E.Str (S.fieldName field),reference (S.fieldType field)] | field <- S.fields constructor],
           E.Ident native] ++ trimmed
             [ E.Array [E.Ident callback | (tag,callback) <- bindings, tag == S.constructorTag constructor]
             , E.Null
             , E.Array (map E.Str (S.constructorIndex constructor))
             , E.Array [E.Array [E.num (toInteger index), reference pattern] | (index, pattern) <- S.constructorRefinements constructor]
             , E.num (toInteger (S.constructorExistentials constructor))
             , E.Array (map (E.num . toInteger) (S.constructorWitnesses constructor)) ]
             [ any ((== S.constructorTag constructor) . fst) bindings, False
             , not (null (S.constructorIndex constructor))
             , not (null (S.constructorRefinements constructor))
             , S.constructorExistentials constructor > 0
             , not (null (S.constructorWitnesses constructor)) ]))
      pure (E.new' "schema.Definition"
        ([E.Str (S.typeName schema),E.num (toInteger (S.parameterCount schema)),E.Array variants] ++
         [E.BoolLit True | S.typeName schema `elem` [C.idText (C.dataId d) | d <- declarations, C.dataHandle d]]))

-- | A module laid out as Prettier lays it out, or on long lines when compact.
printWith :: D.Layout -> Bool -> [E.Stmt] -> String
printWith layout ts = case layout of
  D.Compact -> E.printModuleWidth maxBound dialect
  D.CompactTabs -> E.printModuleWidth maxBound dialect
  _ -> E.printModule dialect
  where dialect = if ts then E.TypeScript else E.JavaScript

-- | The fast-check strategies, placed beside the tests: their imports point
-- at the runtime and schema in src/. Only the paths change, so the module
-- stays as Prettier lays it out.
testStrategies :: Bool -> String
testStrategies ts = (if ts then "// @ts-nocheck\n" else "") ++
  replace "\"./lawspec_schema.mjs\"" ("\"../src/lawspec_schema." ++ extension ++ "\"")
    (replace "\"./lawspec_runtime.mjs\"" ("\"../src/lawspec_runtime." ++ extension ++ "\"") (runtimeSource "web-data-strategies"))
  where extension = if ts then "js" else "mjs"
