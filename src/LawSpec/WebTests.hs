-- | JavaScript and TypeScript tests on LawSpec's portable runtime, with
-- fast-check: each law's examples, boundaries and property as node:test
-- tests, named after the law and the example. Locals keep their source
-- names, text is written as string literals, each test is linked to its
-- source line, and the assertion helpers live in the runtime (ls.check).
-- ref:DEC-portable-exact-arithmetic ref:DEC-readable-output-default
module LawSpec.WebTests (webTests) where

import LawSpec.Backend hiding (inputId, localName, bindings, contractArguments, contractResult)
import qualified LawSpec.Backend as Backend
import qualified Data.Map.Strict as M
import LawSpec.Naming (displayLabel, claimAll, scopeWith, cased, Casing(..))
import LawSpec.TestNames (lawWords)
import LawSpec.SourceLink (unitSourceFile, labelled, locationLink, exampleLocation, originLocation)
import LawSpec.Common
import LawSpec.Testing
import qualified LawSpec.Testing.Cover as Cover
import qualified LawSpec.Core.Value as V
import qualified LawSpec.Core as C
import qualified LawSpec.WebData as WebData
import qualified LawSpec.WebExpr as X
import qualified LawSpec.Code.ECMAScript as E
import qualified LawSpec.Code.Doc as Doc
import LawSpec.Scalar
import LawSpec.MachineSpec (machineSpec)
import LawSpec.Bounds (inputRange)
import LawSpec.Core.Program (Program(..), programSpec)
import qualified LawSpec.Core.Machine as C
import Data.Aeson (toJSON)
import Data.List (intercalate, isPrefixOf, stripPrefix, nub)
import Data.Maybe (listToMaybe)
import Control.Monad (foldM)
import Data.Char (toLower)
import qualified LawSpec.AbilityEmit.Web as WebAbilities
import LawSpec.AbilityNames (specName, recordingName, productionName, interfaceName, ownAbilities, ownerName, unitAbility, unitAbilityPieces)
import LawSpec.Search (lawDescriptors, searchable)
import LawSpec.WebModule (Support(..), webModule, headerComment, linkComment, commentLines, printWebModule)

-- | A unit's tests and its adapter stub.
webTests :: Bool -> Bool -> [C.DataDeclaration] -> [(C.Id,String)] -> Int -> String -> Unit -> [Expanded] -> Either [Diagnostic] [Artifact]
webTests nativeGenerators minify declarations definitions bits target u allLaws = do
  lawGroups <- mapM lawTests (zip [0 :: Int ..] laws)
  modelGroups <- mapM modelTest (C.unitMachines u)
  wrappers <- mapM contractWrapper (contracts u)
  stubGroups <- either (Left . pure . (\m -> Diagnostic "target" m Nothing)) Right (sequence (map stubFunction adapterFunctions ++ map productionStub (ownAbilities u)))
  let -- A unit with supervisors also checks the runtime's supervision.
      supervision = [ [E.ExprStmt (E.call "test" [E.Str (unitName u ++ "::supervision"),
                        E.asyncArrowBlock [] [E.ExprStmt (E.Await (E.call "ls.checkSupervisionAsync" []))]])]
                    | not (null (C.unitSupervisors u)) ]
      benchmarks = map benchmarkTest (maybe [] C.harnessBenchmarks (C.unitHarnessSettings u))
      orderRandom = maybe False C.harnessOrderRandom (C.unitHarnessSettings u)
      parallel = maybe False C.harnessParallel (C.unitHarnessSettings u)
      lawStatements = concatMap (\g -> E.Blank : g) lawGroups
      -- Order random: the law tests are collected, then registered shuffled.
      ordered = if not orderRandom then lawGroups else
        [ [ E.constDecl "_ordered" (E.Array [])
          , E.Block ([E.constDecl "test" (E.arrowBlock [(E.param "registration") { E.paramRest = True }]
                       [E.ExprStmt (E.method (E.Ident "_ordered") "push" [E.Ident "registration"])])] ++ lawStatements)
          , E.ForOf "const" (E.PIdent "registration") (E.call "_harness.shuffled" [E.Ident "_ordered", E.Str (unitName u)])
              [E.ExprStmt (E.call "test" [E.Spread (E.Ident "registration")])] ] ]
      -- parallel: node:test runs the unit's law tests concurrently, in one
      -- suite (its tests keep their names).
      lawsPart = if not parallel then ordered else
        [ [ E.ExprStmt (E.call "_harness.parallelism" [E.Str (unitName u)])
          , E.ExprStmt (E.call "describe" [E.Str (unitName u ++ " laws"), E.Object [E.Prop (E.KName "concurrency") (E.BoolLit True)],
              E.arrowBlock [] (concatMap (\g -> E.Blank : g) ordered)]) ] ]
      groups = lawsPart ++ concat modelGroups ++ supervision ++ benchmarks
      clock = [E.Comment ["// Workflows wait on a virtual clock under test."], E.ExprStmt (E.call "ls.useVirtualClock" [])] ++
        (if installsClock u then [ E.Blank, E.Comment ["// Workflows and mailboxes read the Clock handler a law installs."]
                                 , E.ExprStmt (E.call "registerClock" []) ] else [])
      testSource = printWebModule outputLayout ts (webModule ts
        ([E.Comment ["// @ts-nocheck"] | ts] ++ [headerComment (unitSourceFile u)])
        testImports testSupport (clock : wrappers ++ groups))
      stubSource = printWebModule outputLayout ts (webModule ts [E.Comment ["// User-owned LawSpec adapter."]] stubImports [] stubGroups)
  pure [Artifact stubPath stubSource "user" "source", Artifact testPath testSource "generated" "test"]
  where
    ts = target == "typescript"
    dialectExt = if ts then "js" else "mjs"
    ext = if ts then ".ts" else ".mjs"
    adapterFunctions = [(C.declarationName d,C.declarationType d) | d <- C.unitDeclarations u, C.declarationId d `notElem` map fst definitions]
    hasData = (nativeGenerators || not (null definitions) || not (null declarations) || any (usesData . snd) (functions u) ||
      unitAbilityPieces u || not (null (C.unitAbilities u)) ||
      any (any (usesData . inputType) . inputs) laws ||
      any expressionNeedsSchema (concatMap C.contractExpressions (contracts u) ++
        concatMap (C.propertyExpressions . original) laws))
    fieldContracts = hasConstructorContracts declarations
    usesData = WebData.requiresSchema declarations
    expressionNeedsSchema term | C.AllPayloads _ _ <- C.expressionNode term = True
    expressionNeedsSchema term = usesData (expressionType term) || any expressionNeedsSchema (C.children term)
    nodeCount (V.ScalarValue _) = 1
    nodeCount (V.PresenceValue _ value) = 1 + maybe 0 nodeCount value
    nodeCount value@(V.DataValue (C.Constructor "List" _) _ _) = either (const 1) ((+1) . sum . map nodeCount) (V.listItems value)
    nodeCount (V.DataValue _ _ fields) = 1 + sum (map nodeCount fields)
    budget = maximum ((64 :: Int) : [8 + nodeCount value | law <- laws, requirement <- generationPlan law, value <- generatorBoundaries requirement])
    outputLayout = Doc.selectLayout minify (Doc.Pretty 80)
    referenceOf ty = either error id (WebData.webTypeReference ty)
    parts = split (unitName u)
    slash = intercalate "/" parts
    stubPath = "src/" ++ slash ++ ext
    testPath = "test/" ++ intercalate "_" parts ++ ".lawspec.test" ++ ext
    laws = filter ((== unitName u) . owner) allLaws
    unitParallel = maybe False C.harnessParallel (C.unitHarnessSettings u)
    hasHarness = C.unitHarnessSettings u /= Nothing || any ((/= Nothing) . C.harnessUnit . C.propertyHarness . original) laws
    namespace alias path' = (alias, E.ImportDecl False (E.ImportNamespace alias) path')
    up = concat (replicate (length parts - 1) "../")
    -- Every import a test module may need; it keeps those it uses.
    testImports =
      [namespace "ls" ("../src/lawspec_runtime." ++ dialectExt)] ++
      [namespace "_definitions" ("../src/lawspec_definition_bodies." ++ dialectExt) | not (null definitions)] ++
      [namespace "data" ("../src/lawspec_data." ++ dialectExt) | hasData] ++
      [namespace "schema" ("../src/lawspec_schema." ++ dialectExt) | hasData] ++
      -- A parallel unit's laws run in one describe block.
      [("test", E.ImportDecl False (E.ImportNamed ([("describe", Nothing) | unitParallel] ++ [("test", Nothing)])) "node:test")] ++
      [("fc", E.ImportDecl False (E.ImportDefault "fc") "fast-check")] ++
      [namespace "impl" ("../src/" ++ slash ++ "." ++ dialectExt)] ++
      [namespace "_abilities" ("../src/lawspec_abilities/" ++ slash ++ "." ++ dialectExt) | unitAbilityPieces u] ++
      concat [ [namespace ("_impl" ++ show i) ("../src/" ++ ownerSlash o ++ "." ++ dialectExt),
                namespace ("_abilities" ++ show i) ("../src/lawspec_abilities/" ++ ownerSlash o ++ "." ++ dialectExt)]
             | (i, o) <- zip [0 :: Int ..] foreignOwners ] ++
      [ (boundAlias ps, E.ImportDecl False (E.ImportNamed [(last ps, Just (boundAlias ps))]) ("../src/" ++ intercalate "/" (init ps) ++ "." ++ dialectExt))
      | ps <- boundHandlers ] ++
      [ (failureAlias ps, E.ImportDecl False (E.ImportNamed [(last ps, Just (failureAlias ps))]) ("../src/" ++ intercalate "/" (init ps) ++ "." ++ dialectExt))
      | ps <- failureImports ] ++
      [namespace "_harness" ("./lawspec_harness." ++ dialectExt) | hasHarness] ++
      [("_data_strategy", E.ImportDecl False (E.ImportNamed [("strategy", Just "_data_strategy")])
          ("./" ++ (if nativeGenerators then "lawspec_native_generators" else "lawspec_data_strategies") ++ "." ++ dialectExt)) | hasData] ++
      [("primitiveGenerators", E.ImportDecl False (E.ImportNamed [("primitiveGenerators", Nothing)]) ("./lawspec_data_strategies." ++ dialectExt)) | hasData] ++
      [("registerClock", E.ImportDecl False (E.ImportNamed [("registerClock", Nothing)]) ("../src/lawspec/time." ++ dialectExt)) | installsClock u]
    -- Declarations a test module includes when its code uses them.
    testSupport =
      [ Support "_lawspec_schema" [E.constDecl "_lawspec_schema" (E.call "data.makeSchema" [])]
      , Support "MACHINE_BITS" (X.machineBitsDeclaration bits)
      , Support "primitives" [ E.Comment ["// fast-check's generators for each scalar type, for the data generators."]
                             , E.constDecl "primitives" (E.call "primitiveGenerators" [X.machineBits]) ]
      , Support "dataGenerator" [ E.Comment ["// A generator of a data type's values."]
                                , E.constDecl "dataGenerator" (E.arrow [E.param "type"] (E.call "_data_strategy"
                                    [E.Ident "_lawspec_schema", E.Ident "type", X.machineBits, E.num (toInteger budget),
                                     E.arrow [E.param "name"] (E.index (E.Ident "primitives") (E.Ident "name"))])) ] ]
    stubImports =
      [namespace "data" (up ++ "./lawspec_data." ++ dialectExt) | hasData] ++
      [namespace "schema" (up ++ "./lawspec_schema." ++ dialectExt) | hasData] ++
      [("abilities", E.ImportDecl True (E.ImportNamespace "abilities") (up ++ "./lawspec_abilities/" ++ slash ++ ".js")) | ts, not (null (ownAbilities u))] ++
      [namespace "ls" ((if length parts == 1 then "./" else up) ++ "lawspec_runtime." ++ dialectExt) | hasData]
    -- A native type as TypeScript writes it.
    native ty | usesData ty = either error id (WebData.webDataTypeOf declarations ty)
    native (Applied "Maybe" _) = E.TKeyword "unknown"
    native (C.Constructor "Either" _) = E.TKeyword "unknown"
    native (Applied "List" element) = E.TRef "Array" [if element == Named "Unit" then E.TKeyword "unknown" else native element]
    native (Named n) = case n of
      "Bytes" -> E.TRef "Uint8Array" []; "Bool" -> E.TKeyword "boolean"; "Text" -> E.TKeyword "string"
      "Char" -> E.TKeyword "string"; "Symbol" -> E.TKeyword "symbol"
      "Integer" -> E.TUnion [E.TKeyword "number", E.TKeyword "bigint"]; "Null" -> E.TKeyword "null"
      "Undefined" -> E.TKeyword "undefined"; "Unit" -> E.TKeyword "void"
      _ | isInteger n -> E.TKeyword (if n `elem` ["Int8","Int16","Int32","UInt8","UInt16","UInt32"] then "number" else "bigint")
      _ | n `elem` ["Float32","Float64","CodePoint","CodeUnit16"] -> E.TKeyword "number"
      _ -> E.TKeyword "unknown"
    native _ = E.TKeyword "unknown"
    nativeArg ty | usesData ty = native ty
    nativeArg (Applied "List" element) = E.TRef "Array" [nativeArg element]
    nativeArg t = if t == Named "Integer" then E.TKeyword "bigint" else if t == Named "Unit" then E.TKeyword "unknown" else native t
    -- Each ability's production handler is written by hand, like an adapter.
    productionStub ability = WebAbilities.productionStub ts declarations ability
    -- An adapter's stub: its LawSpec signature in comments, then a function
    -- that throws until it is written.
    stubFunction (n,t) =
      let (args,r) = functionType t
          -- First, a handler for each ability the adapter uses.
          handlerArguments = [ (E.param (handlerParameter ability)) { E.paramType = if ts then Just (maybe (E.TKeyword "unknown") tsInterface (abilityNamed ability)) else Nothing }
                             | d <- C.unitDeclarations u, C.declarationName d == n, ability <- C.declarationUses d, not (C.isFail ability) ]
          arguments = handlerArguments ++ [(E.param ("value" ++ show i)) { E.paramType = if ts then Just (nativeArg a) else Nothing } | (i,a) <- zip [0 :: Int ..] args]
          -- Native representations can erase LawSpec distinctions. Keep the
          -- declared interface visible in both the stub and its canonical key.
          signatureComments = concat [commentLines ("LawSpec argument " ++ show i ++ ": " ++ prettyType a) | (i,a) <- zip [0 :: Int ..] args] ++
            commentLines ("LawSpec result: " ++ prettyType r)
          asyncStub = n `elem` asyncFunctions u
          result = if ts then Just (if asyncStub then E.TRef "Promise" [native r] else native r) else Nothing
      in Right [E.Comment signatureComments, E.FunctionDecl True asyncStub n [] arguments result [E.Throw (E.new' "Error" [E.Str n])]]
    width = X.machineBits
    -- Locals keep their source names, each law's distinct within it.
    locals = M.fromList (concatMap (allocate . propertyBinders . original) laws ++
      concatMap (\c -> allocate (C.contractArguments c ++ [C.contractResult c])) (contracts u))
    allocate binders = M.toList (X.bindingNames testModuleNames binders)
    testModuleNames = words "impl fc test describe ls data schema primitives dataGenerator registerClock _harness _definitions _abilities"
    localName identity = M.findWithDefault (Backend.localName identity) identity locals
    inputId = localName . C.binderId . C.quantifiedBinder
    bindings example = [(localName i, v) | (i, v) <- C.exampleBindings example]
    contractArguments contract = [(localName (C.binderId b), C.binderType b) | b <- C.contractArguments contract]
    contractResult contract = let b = C.contractResult contract in (localName (C.binderId b), C.binderType b)
    -- A failing assertion names its law and case and points at its source.
    shownLaw e = owner e ++ "::" ++ displayLabel (name e)
    expectationLink proposition = case proposition of
      AssertEqual a _ | Just l <- originLocation (C.expressionOrigin a), take 1 (file l) /= "<" -> Just (locationLink l)
      _ -> Nothing
    runtime name' = E.call ("ls." ++ name')
    schema name' arguments = E.call ("_lawspec_schema." ++ name') (arguments ++ [E.Ident "symbols"])
    -- JavaScript tests that call async adapters await them, so their test
    -- bodies, property callbacks and assertion thunks are async too.
    asyncMode = not (null (asyncFunctions u)) || any (isPrefixOf "await " . snd) definitions
    lambda params body = E.Arrow False params Nothing (E.ExpressionBody body)
    thunk body = E.Arrow asyncMode [] Nothing (E.ExpressionBody body)
    callback params body = E.Arrow asyncMode params Nothing (E.BlockBody body)
    awaitIf x = if asyncMode then E.Await x else x
    testCall label body = E.ExprStmt (E.call "test" [E.Str label, callback [] body])
    nativeInput ty value = if usesData ty
      then schema "toNative" [referenceOf ty,value,width] else value
    checkedResult ty value = if usesData ty
      then schema "fromNative" [referenceOf ty,value,width]
      else runtime "validate"
        [if ty == Named "Unit" then runtime "unitResult" [value] else value, E.Str (typeKey ty),width]
    -- A handler's values cross with the handler schema: the bound native
    -- types when lawspec.json binds them (ls.handlerSchema).
    handlerSchema name' args = E.method (runtime "handlerSchema" [E.Ident "_lawspec_schema"]) name' (args ++ [E.Ident "symbols"])
    handlerInput ty value = if usesData ty
      then handlerSchema "toNative" [referenceOf ty,value,width] else value
    handlerResult ty value = if usesData ty
      then handlerSchema "fromNative" [referenceOf ty,value,width]
      else checkedResult ty value
    converted ty value = if usesData ty then schema "validate" [referenceOf ty,value,width]
      else runtime "convert" [value,E.Str (typeKey ty),width]
    -- The handler a law installed for an ability.
    handlerDoc ability = runtime "handler" [E.Ident "symbols", E.Str (C.abilityKey ability)]
    constructed ty tag fields = if usesData ty
      then schema "construct" [referenceOf ty,E.Str tag,E.Array fields,width]
      else runtime "construct" [E.Str tag,E.Array fields]
    equality ty a b = if usesData ty then schema "equal" [referenceOf ty,a,b,width]
      else runtime "equal" [a,b,E.Str (typeKey ty),E.Str (typeKey ty)]
    -- A law's handlers, made afresh for each case and installed in its
    -- symbols, where the code it calls finds them.
    -- A handler of several abilities is made once, and installed for each.
    -- A native handler made with a resource (ability A with T) is made once
    -- the case has acquired its T, inside the bracket.
    installs e = [E.constDecl (sharedName h) (construct plainContext (C.handlerAbility h) (C.SpecHandler (C.handlerId h))) | h <- sharedHandlers e] ++
      installing e [(a, c) | (a, c) <- chosenHandlers e, resourceFor e a c == Nothing]
    lateInstalls e = installing e [(a, c) | (a, c) <- chosenHandlers e, resourceFor e a c /= Nothing]
    installing e chosen = case chosen of
      [] -> []
      _ -> [E.ExprStmt (runtime "installHandlers" [E.Ident "symbols", E.Object
        [E.Prop (E.KString (C.abilityKey ability)) (construct (lawContext e) ability choice) | (ability, choice) <- chosen]])]
    -- What making a law's handlers needs: the handlers it shares, and the
    -- resources its native handlers are made with.
    lawContext e = (sharedHandlers e, resourceFor e)
    plainContext = ([], \_ _ -> Nothing)
    chosenHandlers e = [(ability, choice) | (ability, choice) <- C.propertyHandlers (original e), not (C.isFail ability)]
    sharedHandlers e = nub [h | (_, c) <- chosenHandlers e, h <- specHandlersOf c, not (null (C.handlerAlso h))]
    specHandlersOf c = case c of
      C.SpecHandler h -> [x | x <- C.unitHandlers u, C.handlerId x == h]
      C.RecordingHandler inner -> specHandlersOf inner
      C.ProductionHandler -> []
    sharedName h = "_lawspec_shared_" ++ C.handlerName h
    -- The resource a native handler is made with, as the case holds it.
    resourceFor e ability choice = case choice of
      C.ProductionHandler -> do
        a <- abilityNamed ability
        t <- C.abilityResource a
        r <- listToMaybe [r | r <- C.propertyResources (original e), C.binderType (C.resourceBinder r) == t]
        pure (nativeInput t (E.Ident (localName (C.binderId (C.resourceBinder r)))))
      C.RecordingHandler inner -> resourceFor e ability inner
      C.SpecHandler _ -> Nothing
    construct context@(shared, resourceOf) ability choice = let made = maybe [] pure (resourceOf ability choice) in case choice of
      C.ProductionHandler -> case abilityNamed ability >>= C.abilityNative of
        -- A production handler bound in lawspec.json.
        Just ps -> E.New (E.Ident (boundAlias ps)) [] made
        Nothing -> case abilityNamed ability of
          -- An imported ability's production handler is its owner's.
          Just a | ownerName a /= unitName u -> E.new' (foreignModule "_impl" a ++ "." ++ productionName a) made
          _ -> E.new' ("impl." ++ maybe "Unknown" productionName (abilityNamed ability)) made
      C.SpecHandler h | Just x <- lookup h [(C.handlerId x, x) | x <- shared] -> E.Ident (sharedName x)
      C.SpecHandler h -> E.new' ("_abilities." ++ maybe "Unknown" specName
        (lookup h [(C.handlerId x, x) | x <- C.unitHandlers u])) [E.Ident "symbols"]
      C.RecordingHandler inner -> case abilityNamed ability of
        Just a | ownerName a /= unitName u -> E.new' (foreignModule "_abilities" a ++ "." ++ recordingName a) [construct context ability inner, E.Ident "symbols"]
        _ -> E.new' ("_abilities." ++ maybe "Unknown" recordingName (abilityNamed ability))
          [construct context ability inner, E.Ident "symbols"]
    handlerParameter ability = case maybe "handler" C.abilityName (abilityNamed ability) of
      c : rest -> toLower c : rest
      [] -> "handler"
    boundHandlers = nub [ps | a <- C.unitAbilities u, Just ps <- [C.abilityNative a]]
    boundAlias ps = "_lawspecHandler" ++ show (length (takeWhile (/= ps) boundHandlers))
    abilityNamed = unitAbility u
    failureCallback failure = lambda [E.param "_failure"] (checkedResult failure (E.Ident "_failure"))
    -- An adapter that fails with E: native code raises the runtime's Fail
    -- with a native E (or an exception lawspec.json maps to one), which
    -- becomes the Fail E failure.
    nativeFailures decl invocation = case [a | d <- C.unitDeclarations u, C.declarationId d == decl, a@(C.AbilityRef _ [_]) <- C.declarationUses d, C.isFail a] of
      ability@(C.AbilityRef _ [failure]) : _ | not asyncMode ->
        runtime "nativeFailures" [E.Str (C.abilityKey ability), failureCallback failure, lambda [] invocation, mappedFailures failure]
      -- In async JavaScript a call may await, so its failures are awaited too.
      ability@(C.AbilityRef _ [failure]) : _ ->
        E.Await (runtime "nativeFailuresAsync" [E.Str (C.abilityKey ability), failureCallback failure, E.asyncArrow [] invocation, mappedFailures failure])
      _ -> invocation
    -- An operation that fails with E: a native handler raises the
    -- runtime's Fail with a native E, which becomes the Fail E failure; a
    -- spec handler's raise passes through.
    operationFailures op invocation = case abilityNamed (C.operationAbility op) >>= lookup (C.operationName op) . C.abilityFailures of
      Just ability@(C.AbilityRef _ [failure]) ->
        runtime "nativeFailures" [E.Str (C.abilityKey ability), failureCallback failure, lambda [] invocation, mappedFailures failure]
      _ -> invocation
    mappedFailures failure = E.Array
      [ E.Array [ E.Ident (failureAlias (C.failureNative b))
                , lambda [E.param "_error"] (constructed failure (C.idText (C.failureConstructor b))
                    (C.mapFailureFields (\ty tag -> constructed ty (C.idText tag))
                      (converted (C.scalarType "Text") (E.call "String" [E.Binary "??" (E.Member (E.Ident "_error") "message" True) (E.Ident "_error")])) b)) ]
      | b <- C.unitFailureBindings u, C.failureType b == failure ]
    failureImports = nub [C.failureNative b | b <- C.unitFailureBindings u]
    failureAlias ps = "_lawspecFailure" ++ show (length (takeWhile (/= ps) failureImports))
    -- Units whose abilities this unit imports, in a fixed order.
    foreignOwners = nub [ownerName a | a <- C.unitAbilities u, ownerName a /= unitName u]
    foreignModule prefix a = prefix ++ show (length (takeWhile (/= ownerName a) foreignOwners))
    ownerSlash o = intercalate "/" (split o)
    tsInterface a
      | ownerName a == unitName u = E.TRef ("abilities." ++ interfaceName a) []
      | otherwise = E.TRaw ("import(" ++ E.javascriptLiteral (up ++ "./lawspec_abilities/" ++ ownerSlash (ownerName a) ++ ".js") ++ ")." ++ interfaceName a)
    freshSymbols = E.constDecl "symbols" (E.new' "Map" [])
    -- A case makes symbols when something in it uses them.
    withSymbols e stmts
      | null (installs e) && null (C.propertyResources (original e)) && not (usesSymbols stmts) = stmts
      | otherwise = freshSymbols : installs e ++ stmts
    usesSymbols stmts = "symbols" `elem` words (map (\c -> if c `elem` ('_' : ['a'..'z'] ++ ['A'..'Z'] ++ ['0'..'9']) then c else ' ')
      (E.printModule E.JavaScript stmts))
    -- A law's resources: each case acquires them, then runs, then releases
    -- them, the last first, even when the case fails.
    bracket e stmts = foldr wrap (lateInstalls e ++ stmts) (C.propertyResources (original e))
      where
        -- A shared resource (share R per ...): the runtime keeps one per
        -- scope key, resets it before every use after the first, holds it
        -- for one case at a time, and releases it when the process ends.
        wrap r inner | Just key <- C.resourceShared r, Just reset <- C.resourceReset r =
          let local = localName (C.binderId (C.resourceBinder r))
              shareCall = runtime (if asyncMode then "shareAsync" else "share")
                [E.Str key, thunk (render (C.resourceAcquire r)),
                 E.Arrow asyncMode [E.param local] Nothing (E.ExpressionBody (render reset)),
                 E.Arrow asyncMode [E.param local] Nothing (E.ExpressionBody (render (C.resourceRelease r))),
                 E.BoolLit (C.resourceConcurrent r)]
          in [ E.constDecl local (awaitIf shareCall)
             , E.Try inner Nothing (Just [E.ExprStmt (runtime "unshare" [E.Str key])]) ]
        wrap r inner =
          [ E.constDecl (localName (C.binderId (C.resourceBinder r))) (render (C.resourceAcquire r))
          , E.Try inner Nothing (Just [E.ExprStmt (render (C.resourceRelease r))]) ]
    render term = either error id ((if asyncMode then X.renderAsyncExpression else X.renderExpression)
      ts declarations localName external term)
      where
        external expression values = case C.expressionNode expression of
          -- raise aborts to the nearest attempt of its Fail ability.
          C.Perform op [_] | C.isFail (C.operationAbility op) ->
            Right (runtime "raiseFailure" (E.Str (C.abilityKey (C.operationAbility op)) : values))
          -- An operation goes to the handler installed for its ability.
          C.Perform op args ->
            let invocation = E.method (handlerDoc (C.operationAbility op)) (C.operationName op)
                  [handlerInput (expressionType a) (converted (expressionType a) value) | (a,value) <- zip args values]
            in Right (operationFailures op (handlerResult (expressionType expression) invocation))
          -- handle e with h end: e runs with h installed for its ability.
          C.Handle (C.WithHandler ability choice) _ | [body] <- values ->
            Right (runtime "withHandlers" [E.Ident "symbols",
              E.Object [E.Prop (E.KString (C.abilityKey ability)) (construct plainContext ability choice)],
              lambda [] body])
          C.Handle (C.CatchFailure ability) _ -> case (expressionType expression, values) of
            (C.Constructor "Either" [C.TypeArgument failure, C.TypeArgument result], [body]) ->
              let side tag ty = lambda [E.param "_value"] (constructed (expressionType expression) tag [converted ty (E.Ident "_value")])
                  attempt = runtime (if asyncMode then "attemptAsync" else "attempt") [E.Str (C.abilityKey ability), thunk body,
                    side "Either::Right" result, side "Either::Left" failure]
              in Right (awaitIf attempt)
            _ -> Left "attempt gives an Either"
          C.Calls op args ->
            let matches = case args of
                  Nothing -> E.Null
                  Just xs -> lambda [E.param "_recorded"] (conjunction
                    [equality (expressionType a) (E.index (E.Ident "_recorded") (E.num (toInteger i))) value | (i,(a,value)) <- zip [0 :: Int ..] (zip xs values)])
            in Right (runtime "countCalls" [handlerDoc (C.operationAbility op), E.Str (C.operationName op), matches])
          C.ExternalCall decl args -> case lookup decl definitions of
            -- An asynchronous definition (an async workflow) is awaited.
            Just name' | Just plain <- stripPrefix "await " name' -> Right (E.Await (E.call plain (E.Ident "symbols":values)))
            Just name' -> Right (E.call name' (E.Ident "symbols":values))
            Nothing ->
              let convertedValues = [converted (expressionType a) value | (a,value) <- zip args values]
                  -- A native adapter gets a handler for each ability it uses, first.
                  handlers = [handlerDoc ability | d <- C.unitDeclarations u, C.declarationId d == decl, ability <- C.declarationUses d, not (C.isFail ability)]
                  invocation = awaited (adapterName u decl) (E.call ("impl." ++ adapterName u decl)
                    (handlers ++ [nativeInput (expressionType a) value | (a,value) <- zip args convertedValues]))
              in Right (if declarationName decl `elem` map contractName (contracts u)
                then awaitIf (E.call (contractFunction (declarationName decl)) (E.Ident "symbols":convertedValues))
                else nativeFailures decl (checkedResult (expressionType expression) invocation))
          _ -> Left "expected portable external call"
    contractFunction n = "_lawspec_call_" ++ n
    -- Each law's search names start from its words (normalizersAgreeCase).
    lawStems = fst (claimAll (scopeWith (testModuleNames ++ X.webReserved)) [cased Camel (lawWords (name e)) | e <- laws])
    -- Each expectation is checked by the runtime, which names the law and
    -- case and the source line when it fails.
    assertion' fallback context = assertionWith fallback (\link -> E.Str (labelled context link))
    assertionWith fallback context proposition = case proposition of
      AssertAll propositions -> concatMap (assertionWith fallback context) propositions
      AssertImplies guard body -> [E.If (render guard) (assertionWith fallback context body) Nothing]
      AssertEqual leftE rightE ->
        let message = context (maybe fallback Just (expectationLink proposition))
            structural = usesData (expressionType leftE)
            arguments = if structural
              then [E.Ident "_lawspec_schema", message, thunk (render leftE), thunk (render rightE), referenceOf (expressionType leftE), X.machineBits, E.Ident "symbols"]
              else [message, thunk (render leftE), thunk (render rightE)] ++ map (E.Str . typeKey . expressionType) [leftE,rightE]
            helper = (if structural then "checkData" else "check") ++ (if asyncMode then "Async" else "")
        in [E.ExprStmt (awaitIf (runtime helper arguments))]
      _ -> []
    conjunction expressions = case expressions of
      [] -> E.BoolLit True
      _ -> foldl1 E.and' expressions
    propertyInvocation label generators parameters body options =
      let checked = E.call (if asyncMode then "fc.asyncProperty" else "fc.property") (generators ++ [callback parameters body])
          asserted = awaitIf (E.call "fc.assert" [checked, runtime "seeded" (take 1 (options ++ [E.Object []]))])
      in testCall (label ++ " property") [E.ExprStmt asserted]
    lawTests (index,e) = do
      let label = owner e ++ "::" ++ name e
          harness = C.propertyHarness (original e)
          shown = shownLaw e
          exampleContext example = shown ++ " example " ++ displayLabel (exampleName example)
          lawLink = if null (file (location (original e))) then Nothing else Just (locationLink (location (original e)))
          short = displayLabel (name e)
          linked context link test = [linkComment context link, test]
          examples' = [linked ("example " ++ displayLabel (exampleName example)) (locationLink <$> exampleLocation example) $
            testCall (label ++ " example: " ++ exampleName example)
              (withSymbols e ([E.constDecl n' (render value) | (n',value) <- bindings example] ++
                bracket e (concatMap (assertion' lawLink (exampleContext example)) (expectations example) ++
                  assertion' lawLink shown (assertion e))))
            | example <- examples (original e)]
          finite = finiteCases e
      cover <- either (Left . pure . (\message -> Diagnostic "generation" message Nothing)) Right (caseCover e)
      coverExpression <- caseCoverExpression cover
      let caseIndex = E.Ident "caseIndex"
          values = E.Ident "caseValues"
          number = E.Binary "+" caseIndex (E.num 1)
          caseLabel = E.Binary "+" (E.Str (label ++ " boundary ")) number
          context link = E.Binary "+" (E.Binary "+" (E.Str (shown ++ " boundary ")) number) (E.Str (labelled "" link))
          assigned = [E.constDecl (inputId input) (E.Call (E.index values (E.num (toInteger i))) [] [E.Ident "symbols"] False)
            | (i, input) <- zip [0 :: Int ..] (inputs e)]
          boundaries' = [[linkComment (short ++ ", finite cases") lawLink,
            E.ForOf "const" (E.PArray [E.PIdent "caseIndex", E.PIdent "caseValues"])
              (runtime "finiteCases" [coverExpression])
              [E.ExprStmt (E.call "test" [caseLabel, callback []
                (withSymbols e (assigned ++ bracket e (assertionWith lawLink context (assertion e))))])]]
            | Cover.coverCount cover /= 0]
      -- LawSpec's own search (LawSpec.Search): a failing generated case's
      -- inputs are kept in the failure database, and replayed before the
      -- law's next cases; where fast-check cannot target, a law with
      -- `target maximize` also climbs.
      let descriptors = if searchable (maybe False (const True) finite) (original e) then lawDescriptors bits declarations (original e) else Nothing
          lawStem = lawStems !! index
          descriptorName = lawStem ++ "Inputs"
          remembered stmts = case descriptors of
            Nothing -> stmts
            Just _ -> [E.Try stmts (Just (Just (E.PIdent "error"),
              [ E.ExprStmt (runtime "searchRemember" [E.Str label, E.Ident descriptorName, E.Array (map (E.Ident . inputId) (inputs e))])
              , E.Throw (E.Ident "error") ])) Nothing]
          caseName = lawStem ++ "Case"
          caseDoc = let
              assigned = [E.constDecl (inputId input) (converted (inputType input) (E.index (E.Ident "values") (E.num (toInteger i)))) | (i, input) <- zip [0 :: Int ..] (inputs e)]
              refinements = concatMap inputRefinements (inputs e)
              guardDoc = [E.IfSingle (E.notE (conjunction (map render refinements))) (E.Return (Just E.Null)) | not (null refinements)]
              score = maybe (E.num 0) render (C.harnessTarget harness)
              bodyDoc = withSymbols e (assigned ++ guardDoc ++
                bracket e (assertion' lawLink (shown ++ " search") (assertion e)) ++ [E.ret score])
            in E.FunctionDecl False asyncMode caseName [] [E.param "values"] Nothing bodyDoc
          searchDocs = case descriptors of
            Nothing -> ([], [])
            Just ds ->
              ( [ E.constDecl descriptorName (E.Array (map E.Str ds)), E.Blank, caseDoc, E.Blank
                , E.ExprStmt (E.call "test" [E.Str (label ++ " replay"), E.asyncArrowBlock []
                    [E.ExprStmt (E.Await (runtime "searchReplay" [E.Str label, E.Ident descriptorName, E.Ident caseName]))]]) ]
              , [ E.ExprStmt (E.call "test" [E.Str (label ++ " search"), E.asyncArrowBlock []
                    [E.ExprStmt (E.Await (runtime "searchClimb" [E.Str label, E.Ident descriptorName, E.Ident caseName]))]])
                | C.harnessTarget harness /= Nothing ] )
      let body = observations e ++ remembered (bracket e (assertion' lawLink (shown ++ " property") (assertion e)))
          generators = map (generatorOf . inputType) (inputs e)
          names = map inputId (inputs e)
          ordinary = propertyInvocation label generators (map E.param names) (freshSymbols : installs e ++ body) []
      refined <- (if any (containsStructural . inputType) (inputs e) then nativeRefinedProperty else refinedProperty) label e body
      let needsContext = nativeGenerators || fieldContracts && any (usesData . inputType) (inputs e)
            || any (maybe False (const True) . generatorIndex) (generationPlan e)
      contextual <- if needsContext then webContextualProperty label e body else pure ordinary
      drawn <- if not (null (C.harnessDraws harness)) then pure <$> harnessProperty label e body else pure []
      let properties = if maybe False (const True) finite then [] else
            if not (null drawn) then drawn else
            [if needsContext then contextual else if any (not . null . inputRefinements) (inputs e) || propertyKind e == "contract" then refined else ordinary]
          tests = examples' ++ boundaries' ++ map (linked (short ++ ", property") lawLink) properties
      pure ([E.Comment (concatMap commentLines (lawCommentLines e))] ++ fst searchDocs ++ [E.Blank | not (null (fst searchDocs))] ++
            webHarness label harness tests ++ concatMap (\t -> [E.Blank, t]) (snd searchDocs))
    -- The harness plane (LawSpec.Harness). A law whose harness sets how its
    -- tests run (timeout, repeat, retry flaky, adequacy) has each test
    -- wrapped: the generated test calls the runtime with the law's own test.
    runSettings harness = C.harnessTimeout harness /= Nothing || C.harnessRepeat harness /= 1 ||
      C.harnessRetries harness /= 0 || observed harness
    observed harness = not (null (C.harnessCover harness) && null (C.harnessClassify harness) &&
      null (C.harnessLabels harness)) || C.harnessTarget harness /= Nothing
    -- What a generated case covers, classifies and labels, and the score
    -- targeted search maximizes. Only property tests observe.
    observations e =
      let harness = C.propertyHarness (original e)
          label = owner e ++ "::" ++ name e
          fields = [("covers", E.Array [E.Array [E.Str l, render w] | C.Cover _ l w <- C.harnessCover harness]) | not (null (C.harnessCover harness))] ++
            [("classes", E.Array [E.Array [E.Str l, render c] | (c, l) <- C.harnessClassify harness]) | not (null (C.harnessClassify harness))] ++
            [("labels", E.Array (map render (C.harnessLabels harness))) | not (null (C.harnessLabels harness))]
      in if not (observed harness) then [] else
        [E.ExprStmt (E.call "_harness.observe" [E.Str label, object fields])] ++
        [E.ExprStmt (E.call "_harness.target" [render score, E.Str label]) | Just score <- [C.harnessTarget harness]]
    object fields = E.Object [E.Prop (E.KName k) v | (k, v) <- fields]
    -- JavaScript and TypeScript register a law's tests through `test`; a
    -- harness redefines it in a block around them, so each registered test
    -- runs under the harness (run settings), is collected (known failing), or
    -- is replaced by one skipped test.
    webHarness label harness tests =
      let register = E.constDecl "_register" (E.Ident "test")
          rendered = concatMap (\t -> E.Blank : t) tests
      in case (C.harnessSkip harness, C.harnessKnownFailing harness) of
        (Just reason, _) -> [E.ExprStmt (E.call "test" [E.Str (label ++ " skipped"), object [("skip", E.Str reason)],
          lambda [] (E.call "_harness.skip" [E.Str label, E.Str reason])])]
        (_, Just reason) -> [E.Block
          [ register, E.constDecl "_known" (E.Array [])
          , E.Block (E.constDecl "test" (E.arrowBlock [E.param "_name", E.param "body"] [E.ExprStmt (E.method (E.Ident "_known") "push" [E.Ident "body"])]) : rendered)
          , E.ExprStmt (E.call "_register" [E.Str (label ++ " known failing"), lambda []
              (E.call "_harness.knownFailing" [E.Str label, E.Str (label ++ " known failing"), E.Str reason, E.Ident "_known"])]) ]]
        _ | runSettings harness -> [E.Block
              [ register
              , E.Block (E.constDecl "test" (E.arrow [E.param "name", E.param "body"] (E.call "_register" [E.Ident "name", lambda []
                  (E.call "_harness.run" [E.Str label, E.Ident "name", E.Ident "body", object
                    ([("timeout", E.num (toInteger ms)) | Just ms <- [C.harnessTimeout harness]] ++
                     [("repeat", E.num (toInteger (C.harnessRepeat harness))) | C.harnessRepeat harness /= 1] ++
                     [("retries", E.num (toInteger (C.harnessRetries harness))) | C.harnessRetries harness /= 0] ++
                     [("covers", E.Array [E.Array [E.Num (show pc), E.Str l] | C.Cover pc l _ <- C.harnessCover harness]) | not (null (C.harnessCover harness))] ++
                     [("observed", E.method (E.Ident "name") "endsWith" [E.Str " property"]) | observed harness])])])) : rendered) ]]
          | otherwise -> concat (zipWith (\i t -> if i == (0 :: Int) then t else E.Blank : t) [0 ..] tests)
    -- A property whose inputs a harness strategy draws: fast-check composes
    -- a strategy into one arbitrary (oneof, filter, chain), so its
    -- shrinking follows the strategy's structure. Values are built with
    -- symbols made for generation.
    harnessProperty label e body = do
      let harness = C.propertyHarness (original e)
          strategyOf input = [(n, d) | (i, n, d) <- C.harnessDraws harness, i == C.binderId (C.quantifiedBinder input)]
      arbitraries <- mapM (\plan -> case strategyOf (domainInput plan) of
        (strategy, draw) : _ -> webArbitrary e plan draw >>= \a -> pure (Just strategy, a)
        [] -> (\a -> (Nothing, a)) <$> contextStrategy e plan) (generationPlan e)
      let checks = concat
            [ case strategy of
                Just name' -> [E.ExprStmt (E.call "_harness.checkDrawn" [E.Str name', E.Str (inputName input),
                  lambda [E.param (inputId input)] (conjunction (map render (inputRefinements input))), E.Ident (inputId input)])
                  | not (null (inputRefinements input))]
                Nothing -> [E.ExprStmt (E.call "fc.pre" [conjunction (map render (inputRefinements input))]) | not (null (inputRefinements input))]
            | ((strategy, _), plan) <- zip arbitraries (generationPlan e), let input = domainInput plan ]
          generated = [E.Call (lambda [E.param "symbols"] a) [] [E.Ident "_generation"] False | (_, a) <- arbitraries]
      pure (testCall (label ++ " property")
        [ E.constDecl "_generation" (E.new' "Map" [])
        , E.ExprStmt (awaitIf (E.call "fc.assert"
            [ E.call (if asyncMode then "fc.asyncProperty" else "fc.property")
                (generated ++ [callback (map (E.param . inputId) (inputs e)) ([freshSymbols] ++ installs e ++ checks ++ body)])
            , runtime "seeded" [object [("numRuns", E.num (toInteger (cases (generation e))))]] ])) ])
    -- A strategy as one fast-check arbitrary.
    webArbitrary e plan draw = case draw of
      C.DrawAny ty (Just aim)
        | Just range <- inputRange bits aim -> pure (generatorWithin (Just range) ty)
      C.DrawAny ty _
        | ty == inputType (domainInput plan) -> contextStrategy e plan
        | otherwise -> pure (generatorOf ty)
      C.DrawOneOf _ values -> pure (E.method (E.call "fc.integer" [object [("min", E.num 0), ("max", E.num (toInteger (length values - 1)))]]) "map"
        [lambda [E.param "_choice"] (E.Call (E.index (E.Array [lambda [] (render v) | v <- values]) (E.Ident "_choice")) [] [] False)])
      C.DrawFrequency alternatives -> do
        options <- mapM (\(w, d) -> (\a -> object [("arbitrary", a), ("weight", E.num (toInteger w))]) <$> webArbitrary e plan d) alternatives
        pure (E.call "fc.oneof" options)
      C.DrawSuchThat inner binder predicate _ -> do
        a <- webArbitrary e plan inner
        pure (E.method a "filter" [lambda [E.param (localName (C.binderId binder))] (render predicate)])
      C.DrawBind binder from rest -> do
        fromA <- webArbitrary e plan from
        restA <- webArbitrary e plan rest
        pure (E.method fromA "chain" [lambda [E.param (localName (C.binderId binder))] restA])
    -- A benchmark: measured, never asserted.
    benchmarkTest (n, body) =
      [E.ExprStmt (E.call "test" [E.Str ("benchmark " ++ n), E.asyncArrowBlock []
        [freshSymbols, E.ExprStmt (E.Await (E.call "_harness.benchmark" [E.Str n, thunk (render body)]))]])]
    -- A stateful model's test: the model runtime generates runs, executes
    -- them through the generated bridge definitions and checks them against
    -- the reference definitions.
    modelTest machine = do
      spec <- either (\m -> Left [Diagnostic "model" m Nothing]) Right
        (machineSpec bits declarations (C.unitDeclarations u) (C.unitContracts u) machine)
      let callOf identity = case lookup identity definitions of
            Just name' -> Right (E.Ident (maybe name' id (stripPrefix "await " name')))
            Nothing -> Left [Diagnostic "model" ("model " ++ C.machineName machine ++ ": " ++ C.idText identity ++ " is not a checked definition") Nothing]
          optional = maybe (pure E.Null) callOf
      start <- case C.machineStart machine of
        Just s -> (\r m -> E.Array [r, m]) <$> callOf (C.startRun s) <*> callOf (C.startModel s)
        Nothing -> pure E.Null
      commands <- mapM (\c -> (\r f w -> E.Array [r, f, w]) <$> callOf (C.commandRun c) <*> callOf (C.commandReference c) <*> optional (C.commandWhen c))
        (C.machineCommands machine)
      abstract <- optional (C.machineAbstractRun machine)
      invariants <- mapM (\i -> callOf (case i of C.OnModel f -> f; C.OnState f -> f)) (C.machineInvariants machine)
      let model = E.new' "ls.Model" [E.Str spec, start, E.Array commands, abstract, E.Array invariants]
          label = unitName u ++ "::model " ++ C.machineName machine
          -- JavaScript callbacks may be async definitions, so the model
          -- runtime awaits each one.
          check name' extra = E.ExprStmt (E.call "test" [E.Str name', E.asyncArrowBlock [] [E.ExprStmt (E.Await (runtime extra [model]))]])
          -- Each scenario of the model runs on many schedules.
          scenario program = E.ExprStmt (E.call "test" [E.Str (label ++ "::scenario " ++ programTitle program), E.asyncArrowBlock []
            [E.ExprStmt (E.Await (runtime "checkScenarioAsync" [model, E.Str (programSpec program)]))]])
      pure ([[check label "checkModelAsync"]] ++
        -- A shared model's commands also run at the same time; every
        -- history must be linearizable.
        [[check (label ++ " parallel") "checkModelParallelAsync"] | C.machineShared machine] ++
        [[scenario program] | program <- C.machineScenarios machine])
    -- An async adapter's task is awaited where it is called.
    awaited name' invocation
      | name' `notElem` asyncFunctions u = invocation
      | otherwise = E.Await invocation
    contractWrapper contract =
      let arguments = contractArguments contract
          (resultName,resultType) = contractResult contract
          require label predicates = E.ExprStmt (runtime "requireContract"
            [conjunction (map render predicates), E.Str (contractName contract ++ " " ++ label ++ ": " ++
              intercalate " && " (map (prettyExprWith True localName) predicates))])
          invocation = awaited (adapterName u (C.contractDeclaration contract)) (E.call ("impl." ++ adapterName u (C.contractDeclaration contract))
            [nativeInput ty (converted ty (E.Ident n)) | (n,ty) <- arguments])
      in pure [ linkComment (contractName contract) Nothing
              , E.FunctionDecl False asyncMode (contractFunction (contractName contract)) [] (map E.param ("symbols":map fst arguments))
                  Nothing
                  [ require "precondition" (contractPreconditions contract)
                  , E.constDecl resultName (checkedResult resultType invocation)
                  , require "postcondition" (contractPostconditions contract)
                  , E.ret (E.Ident resultName) ] ]
    caseCoverExpression (Cover.Complete count) = pure (E.num (toInteger count))
    caseCoverExpression (Cover.Alternatives alternatives) = E.Array <$> mapM branch alternatives
      where
        branch (domain, suffix) = do
          values <- case domain of
            Cover.Values items -> do
              literals <- mapM valueLit items
              pure (E.Array [E.num 0, E.Array [E.arrow [E.param "symbols"] literal | literal <- literals]])
            Cover.IntegerInterval name first last' -> do
              endpoints <- mapM (valueLit . V.ScalarValue . SInteger name) [first, last']
              pure (E.Array (E.num 1 : endpoints))
          rest <- caseCoverExpression suffix
          pure (E.Array [values, rest])
    valueLit (V.ScalarValue value) = Right (case X.scalarLiteral value of
      Just native' | plainScalar value -> native'
      _ -> runtime "literal" [X.literalValue (toJSON value), E.Ident "symbols"])
    valueLit value@(V.DataValue (C.Constructor "List" _) _ _) = do
      items <- either (Left . pure . (\message -> Diagnostic "target" message Nothing)) Right (V.listItems value)
      E.Array <$> mapM valueLit items
    valueLit (V.PresenceValue (C.Constructor wrapper _) payload) = do
      field <- traverse valueLit payload
      pure (E.new' "ls.Presence" (E.Str wrapper : case field of
        Nothing -> [E.BoolLit False]
        Just value -> [E.BoolLit True, value]))
    valueLit (V.DataValue ty tag fields) | usesData ty = do
      values <- mapM valueLit fields
      pure (schema "construct" [referenceOf ty,E.Str (C.idText tag),E.Array values,width])
    valueLit (V.DataValue (C.Constructor n _) tag fields) | n `elem` ["Maybe","Either"] = do
      values <- mapM valueLit fields
      pure (runtime "construct" [E.Str (C.idText tag),E.Array values])
    valueLit _ = Left [Diagnostic "target" ("structural literal is not implemented for " ++ target) Nothing]
    -- A boundary's scalar is its type's own, so its native value needs no
    -- conversion.
    plainScalar value = case value of
      SBool _ -> True
      SInteger t _ -> isInteger t
      SSequence t _ -> t `elem` ["Text", "Bytes"]
      SCharacter t _ -> t `elem` ["Char", "CodePoint", "CodeUnit16"]
      _ -> False
    containsStructural ty | usesData ty = True
    containsStructural (C.Constructor n args) = n `elem` ["List","Maybe","Either"] ||
      any (\arg -> case arg of C.TypeArgument inner -> containsStructural inner; _ -> False) args
    containsStructural _ = False
    contextStrategy e plan = do
      let input = domainInput plan
          ty = inputType input
      seeds <- mapM valueLit (generatorBoundaries plan)
      let hints = [render hint | hint <- generatorHints plan,
            C.expressionType hint == ty, case C.expressionNode hint of
              C.Constant _ -> True
              C.Local _ -> True
              _ -> False]
          -- Seed values are supplementary draws, so they must obey the same
          -- restrictions as the narrowed scalar generator. Recompute them in
          -- the actual lexical prefix on every draw/shrink. Earlier restrictions
          -- guard partial expressions in later restrictions in source order.
          prefix = takeWhile ((/= inputId input) . inputId) (inputs e) ++ [input]
          predicates = concatMap inputRefinements prefix
          candidates = E.Array (seeds ++ hints)
          accepted = lambda [E.param (inputId input)] (conjunction (map render predicates))
          witnesses
            | null predicates = candidates
            | otherwise = E.method candidates "filter" [accepted]
          scalarKey = E.Ident "scalarName"
          fallback = E.index (E.Ident "primitives") scalarKey
          scalar = case inputRange bits (domainInput plan) of
            Nothing -> lambda [E.param "name"] (E.index (E.Ident "primitives") (E.Ident "name"))
            Just range ->
              lambda [E.param "scalarName"] (E.Conditional (E.Binary "===" scalarKey (E.Str (typeKey ty)))
                (generatorWithin (Just range) ty) fallback)
      pure (case requiredSymbol plan of
        value:_ -> E.call "fc.constant" [render value]
        [] -> E.call "_data_strategy"
          ([E.Ident "_lawspec_schema",referenceOf ty,width,E.num (toInteger budget),
            scalar,E.Ident "symbols",witnesses] ++
            [E.num (toInteger (maxAttempts (generation e)))] ++
            -- The generated native wrapper takes index directly; the shared
            -- runtime receives its default native generators and schema.
            [E.Ident "undefined" | not nativeGenerators, generatorIndex plan /= Nothing] ++
            [E.Ident "undefined" | not nativeGenerators, generatorIndex plan /= Nothing] ++
            maybe [] (pure . indexDoc) (generatorIndex plan)))
    -- Index-directed generation: the target is evaluated from earlier draws.
    indexDoc indexed =
      E.Array [render (indexedTarget indexed), E.Object
        [E.Prop (E.KString (C.idText tag)) (E.Array (map E.Str texts)) | (tag,texts) <- indexedEquations indexed]]
    webContextualProperty label e body = do
      let state names' = object [("_values",E.Array names'),("symbols",E.Ident "symbols")]
          initial = E.method (E.call "fc.constant" [E.Null]) "map"
            [lambda [] (object [("_values",E.Array []),("symbols",E.new' "Map" [])])]
          step source (index',plan) = do
            strategy <- contextStrategy e plan
            let previous = map (E.Ident . inputId) (take index' (inputs e))
                mapped = E.method strategy "map" [lambda [E.param "_value"] (state (previous ++ [E.Ident "_value"]))]
            pure (E.method source "chain" [E.Arrow False [objectParam previous] Nothing (E.ExpressionBody mapped)])
          objectParam previous = E.Param (E.PObject [("_values", Just (E.PArray [E.PIdent n | E.Ident n <- previous])), ("symbols", Nothing)]) Nothing Nothing False
      cases' <- foldM step initial (zip [0 :: Int ..] (generationPlan e))
      let predicate = conjunction (map render (concatMap inputRefinements (inputs e)))
          cfg = generation e
          checkedBody = [E.ExprStmt (E.call "fc.pre" [predicate])] ++ installs e ++ body
      pure (propertyInvocation label [cases'] [objectParam (map (E.Ident . inputId) (inputs e))]
        checkedBody [object [("numRuns",E.num (toInteger (cases cfg))), ("maxSkipsPerRun",E.num (toInteger (maxAttempts cfg)))]])
    -- Identity equality restricts Symbol to one fixture. Only required
    -- conjuncts qualify; an equality under disjunction does not define a domain.
    requiredSymbol plan
      | nativeGenerators = []
      | inputType (domainInput plan) /= C.scalarType "Symbol" = []
      | otherwise = concatMap required (generatorPredicates plan)
      where
        current = C.binderId (generatorBinder plan)
        required expression = case C.expressionNode expression of
          C.ShortCircuit C.And a b -> required a ++ required b
          C.Binary C.Equal _ a b -> [value | (local,value) <- [(a,b),(b,a)],
            C.expressionNode local == C.Local current,
            C.expressionType value == C.scalarType "Symbol",
            current `notElem` C.freeBinders value,
            case C.expressionNode value of
              C.Constant _ -> True
              C.Local _ -> True
              _ -> False]
          _ -> []
    nativeRefinedProperty label e body =
      let -- An integer input draws from its refinement's constant range;
          -- the filter still checks every refinement.
          generators = [hinted input (generatorWithin (inputRange bits input) (inputType input)) | input <- inputs e]
          -- Constant hints (regex samples, compared literals) are mixed in so
          -- a narrow refinement still meets the filter often enough.
          hinted input generator = case [render hint | plan <- generationPlan e,
              inputId (domainInput plan) == inputId input, hint <- generatorHints plan,
              C.expressionType hint == inputType input, isConstant hint,
              C.expressionType hint /= C.scalarType "Symbol", withinRange input hint] of
            [] -> generator
            -- Literals render against a symbol table; these hold no symbols,
            -- so a throwaway table is enough outside a case.
            hints -> let values = E.Call (lambda [E.param "symbols"] (E.Array hints)) [] [E.new' "Map" []] False
              in E.call "fc.oneof" [E.call "fc.constantFrom" [E.Spread values], generator]
          withinRange input hint = case (inputRange bits input,C.expressionNode hint) of
            (Just (lo,hi),C.Constant (SInteger _ value)) -> value >= lo && value <= hi
            _ -> True
          isConstant hint = case C.expressionNode hint of
            C.Constant _ -> True
            _ -> False
          predicate = conjunction (map render (concatMap inputRefinements (inputs e)))
          cfg = generation e
          tuple = E.call "fc.tuple" generators
          caseValue = object [("_values",E.Ident "_values"),("symbols",E.new' "Map" [])]
          mapped = E.method tuple "map" [lambda [E.param "_values"] caseValue]
          pattern = E.Param (E.PObject [("_values", Just (E.PArray [E.PIdent (inputId i) | i <- inputs e])), ("symbols", Nothing)]) Nothing Nothing False
          condition = E.Arrow False [pattern] Nothing (E.ExpressionBody predicate)
          filtered = E.method mapped "filter" [condition]
      in pure (propertyInvocation label [filtered] [pattern] (installs e ++ body)
          [object [("numRuns",E.num (toInteger (cases cfg))),("maxSkipsPerRun",E.num (toInteger (maxAttempts cfg)))]])
    refinedProperty label e body = do
      domains <- mapM (domainCode e) (zip [0 :: Int ..] (generationPlan e))
      let cfg = generation e
          checkBody = [E.constDecl (inputId input) (E.index (E.Ident "values") (E.num (toInteger index'))) |
            (index',input) <- zip [0 :: Int ..] (inputs e)] ++ installs e ++ body
          check = E.constDecl "check" (callback [E.param "values"] checkBody)
          run = E.ExprStmt (awaitIf (runtime (if asyncMode then "refinedCaseAsync" else "refinedCase")
            [E.Array domains,E.Ident "seed",E.num (toInteger (maxAttempts cfg)),E.num (toInteger (maxShrinks cfg)),E.Ident "check",
             E.Str (label ++ " | " ++ intercalate "; " (map (prettyExprWith True (sourceNames (original e))) (concatMap inputRefinements (inputs e))))]))
      pure (propertyInvocation label [E.call "fc.integer" [object [("min",E.num 0),("max",E.num 2147483647)]]]
        [E.param "seed"] [freshSymbols, check, run] [object [("numRuns",E.num (toInteger (cases cfg)))]])
    domainCode e (index',plan) = do
      seeds <- mapM valueLit (generatorBoundaries plan)
      let input = domainInput plan
          previous = take index' (inputs e)
          bind inputs' seeded expression =
            let names' = map (E.PIdent . inputId) inputs'
            in E.Arrow False (E.Param (E.PArray names') Nothing Nothing False : [E.param "seed" | seeded]) Nothing (E.ExpressionBody expression)
          bounds = [E.Array [E.Str operator,render value] | (operator,value) <- domainBounds plan]
          candidates = runtime "domainCandidates"
            [E.Str (typeKey (inputType input)),E.Ident "seed",width,E.Array bounds,
             E.Array (seeds ++ map render (generatorHints plan))]
          predicate = conjunction (map render (inputRefinements input))
      pure (E.Array [bind previous True candidates,bind (previous ++ [input]) False predicate])
    -- fast-check generators for a type, from the same plan as Python's
    -- Hypothesis strategies. ref:DEC-native-property-frameworks
    generatorOf = generatorWithin Nothing
    generatorWithin within = generate
      where
        integerRange low high = E.call "fc.integer" [object [("min",E.num low),("max",E.num high)]]
        list source = E.call "fc.array" [source, object [("maxLength",E.num 100)]]
        mapped source parameter body = E.method source "map" [lambda [E.param parameter] body]
        scalarCodePoint = E.method (integerRange 0 1114111) "filter"
          [lambda [E.param "x"] (E.or' (E.Binary "<" (E.Ident "x") (E.num 55296)) (E.Binary ">" (E.Ident "x") (E.num 57343)))]
        scalarLiteral value = E.call "ls.literal" [X.literalValue (toJSON value)]
        boundariesOf (Applied n t) = SPresent n Nothing : map (SPresent n . Just) (boundariesOf t)
        boundariesOf (Named n) = scalarBoundaries bits n
        boundariesOf _ = []
        bound value
          | value == 2^(256::Int) = E.Binary "**" (E.BigIntLit "2") (E.BigIntLit "256")
          | value == -2^(256::Int) = E.Unary "-" (E.Binary "**" (E.BigIntLit "2") (E.BigIntLit "256"))
          | value < 0 = E.Unary "-" (E.BigIntLit (show (negate value)))
          | otherwise = E.BigIntLit (show value)
        generate ty | usesData ty = E.call "dataGenerator" [referenceOf ty]
        generate (Applied "Maybe" inner) =
          E.call "fc.oneof" [E.call "fc.constant" [E.call "ls.construct" [E.Str "Maybe::Absent", E.Array []]],
            mapped (generate inner) "value" (E.call "ls.construct" [E.Str "Maybe::Present", E.Array [E.Ident "value"]])]
        generate (C.Constructor "Either" [C.TypeArgument leftT,C.TypeArgument rightT]) =
          let branch tag inner = mapped (generate inner) "value" (E.call "ls.construct" [E.Str tag, E.Array [E.Ident "value"]])
          in E.call "fc.oneof" [branch "Either::Left" leftT, branch "Either::Right" rightT]
        generate (Applied "List" inner) = E.call "fc.array" [generate inner, object [("maxLength", E.num 64)]]
        generate (Applied n inner) = E.call "fc.oneof"
          [E.call "fc.constant" [E.new' "ls.Presence" [E.Str n, E.BoolLit False]],
           mapped (generate inner) "x" (E.new' "ls.Presence" [E.Str n, E.BoolLit True, E.Ident "x"])]
        generate t@(Named n)
          | isInteger n =
              let bounds = maybe (integerBounds bits n) Just within
                  low = maybe (if n == "BigUInt" then 0 else -2^(256::Int)) fst bounds
                  high = maybe (2^(256::Int)) snd bounds
              in mapped (E.call "fc.bigInt" [object [("min",bound low),("max",bound high)]]) "x"
                   (E.call "ls.convert" [E.Ident "x", E.Str n, X.machineBits])
          | n == "Bool" = E.call "fc.boolean" []
          | n == "Text" = mapped (list scalarCodePoint) "xs"
              (E.method (mapped (E.Ident "xs") "x" (E.call "String.fromCodePoint" [E.Ident "x"])) "join" [E.Str ""])
          | n `elem` ["Float32","Float64"] = E.call (if n == "Float32" then "fc.float" else "fc.double") []
          | n == "Decimal" = mapped (E.call "fc.tuple" [E.call "fc.bigInt" [], integerRange (-20) 20]) "v"
              (E.new' "ls.Decimal" [E.index (E.Ident "v") (E.num 0), E.index (E.Ident "v") (E.num 1)])
          | n == "Rational" = mapped (E.call "fc.tuple" [E.call "fc.bigInt" [], E.call "fc.bigInt" [object [("min", E.BigIntLit "1")]]]) "v"
              (E.new' "ls.Rational" [E.index (E.Ident "v") (E.num 0), E.index (E.Ident "v") (E.num 1)])
          | n `elem` ["Complex64","Complex128"] =
              let component = generate (Named (if n == "Complex64" then "Float32" else "Float64"))
              in mapped (E.call "fc.tuple" [component,component]) "v"
                (E.new' "ls.Complex" [E.index (E.Ident "v") (E.num 0), E.index (E.Ident "v") (E.num 1)])
          | n == "Char" = mapped scalarCodePoint "x" (E.call "String.fromCodePoint" [E.Ident "x"])
          | n `elem` ["CodePoint","CodeUnit16"] = integerRange 0 (maximumUnit n)
          | n == "Bytes" = mapped (list (integerRange 0 255)) "v" (E.new' "Uint8Array" [E.Ident "v"])
          | n `elem` ["CodePointText","Utf16Text"] = mapped (list (integerRange 0 (maximumUnit n))) "v"
              (E.new' "ls.Raw" [E.Str n, E.Ident "v"])
          | n == "Symbol" = mapped (E.call "fc.string" []) "x" (E.call "Symbol" [E.Ident "x"])
          | otherwise = E.call "fc.constantFrom" (map scalarLiteral (boundariesOf t))
        generate _ = error "unsupported portable generator type"
        maximumUnit :: String -> Integer
        maximumUnit n = if n == "Bytes" then 255 else if n `elem` ["CodeUnit16","Utf16Text"] then 65535 else 1114111
    split s = case break (== '.') s of (a,[]) -> [a]; (a,_:b) -> a:split b

-- | Runtime calls name a value's type by a stable key.
typeKey :: Type -> String
typeKey = scalarTypeKey

-- Whether a unit's laws install a Clock handler: its tests then register how
-- the runtime reads one (lawspec.time's register_clock).
installsClock :: C.Unit -> Bool
installsClock unit = or [C.abilityKey a == "lawspec.time::ability::Clock" | p <- C.unitProperties unit, (a, _) <- C.propertyHandlers p]
