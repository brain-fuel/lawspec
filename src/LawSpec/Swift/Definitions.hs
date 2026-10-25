-- | Each unit's entries in Swift: its checked definitions, evaluated on
-- portable values, and a bridge to each adapter that converts values to the
-- adapter's native types and back, checking contracts on the way. Tests,
-- definitions and the embedding API all call these same entries.
-- ref:DEC-total-definitions ref:DEC-native-bindings-typed-identity
module LawSpec.Swift.Definitions
  ( emitEntries, emitEntriesWithLayouts, emitAdapters, adapterDeclarations, nativeSignature, emitApi, declarationFailure
  , failureKey, TypedCall, isUnit, signatureText
  ) where

import qualified LawSpec.Core as C
import qualified LawSpec.Code.Doc as D
import LawSpec.Core.DefinitionContracts (checkedDefinitionContracts)
import LawSpec.Core.Evidence (runtimePostconditions)
import LawSpec.Common (Artifact(..))
import LawSpec.Swift.Code
import LawSpec.SourceLink (generatedHeader, unitSourceFile)
import LawSpec.Swift.Names
import qualified LawSpec.Swift.Data as Data
import qualified LawSpec.Swift.Expr as X
import LawSpec.Swift.Entries
import qualified LawSpec.Swift.Effects as Effects
import qualified LawSpec.Swift.Abilities as Abilities
import qualified LawSpec.Swift.Policy as Policy
import qualified LawSpec.AbilityNames as N
import LawSpec.NativeRequest (NativeCall(..))
import LawSpec.NativeBinding (NativeRef(..), ResolvedTypeBinding, usesNativeLayout)
import Control.Monad (forM)
import Data.List (intercalate)
import LawSpec.Naming (claimAll, scopeWith)
import qualified LawSpec.Naming as Naming

-- | The adapters bound in lawspec.json to application code, by declaration.
type Calls = [(C.Id, NativeCall)]

-- | The declarations a unit's adapter implements: those that are not definitions.
adapterDeclarations :: C.Unit -> [C.Declaration]
adapterDeclarations u = [d | d <- C.unitDeclarations u,
  C.declarationId d `notElem` map (C.declarationId . C.definitionDeclaration) (C.unitDefinitions u)]

-- | Unit, which native signatures leave out of their arguments and results.
isUnit :: C.Type -> Bool
isUnit t = t == C.Constructor "Unit" []

-- | The failure type of a declaration that fails with one.
declarationFailure :: C.Declaration -> Maybe C.Type
declarationFailure d = case [f | C.AbilityRef _ [f] <- filter C.isFail (C.declarationUses d)] of
  f : _ -> Just f
  [] -> Nothing

failureKey :: C.Declaration -> String
failureKey d = case filter C.isFail (C.declarationUses d) of
  ref : _ -> C.abilityKey ref
  [] -> ""

-- | An adapter's native parameters (handlers first, then values without
-- Unit), its result (Void for Unit), its failure, and whether it is async.
nativeSignature :: Int -> Data.Names -> [C.Unit] -> C.Declaration -> Either String ([(String, String)], String, Maybe String, Bool)
nativeSignature bits names units d = do
  let (parameters, result) = C.functionType (C.declarationType d)
  handlers <- forM (Effects.uses d) $ \ref -> do
    a <- maybe (Left ("unknown Swift ability " ++ C.abilityKey ref)) Right (N.abilityOf units ref)
    pure (camel (N.interfaceName a), "any " ++ Effects.protocolType a)
  ps <- mapM (Data.nativeType bits names []) [p | p <- parameters, not (isUnit p)]
  r <- if isUnit result then pure "Void" else Data.nativeType bits names [] result
  failure <- traverse (Data.nativeType bits names []) (declarationFailure d)
  pure (handlers ++ zip [parameterName i | i <- [0 ..]] ps, r, failure, C.declarationAsync d)

-- | A function's declaration: its signature, with its parameters on one
-- line or one a line, and its body.
signatureDoc :: String -> String -> [(String, String)] -> String -> Maybe String -> Bool -> D.Doc -> D.Doc
signatureDoc keywords name params result failure async =
  signature (keywords ++ " " ++ name) ["_ " ++ p ++ ": " ++ t | (p, t) <- params]
    ((if async then " async" else "") ++ maybe "" (\e -> " throws(" ++ e ++ ")") failure ++
     (if result == "Void" then "" else " -> " ++ result))

-- | A function's signature text: name(params) async throws(E) -> R.
signatureText :: String -> [(String, String)] -> String -> Maybe String -> Bool -> String
signatureText name params result failure async =
  name ++ "(" ++ intercalate ", " ["_ " ++ p ++ ": " ++ t | (p, t) <- params] ++ ")" ++
  (if async then " async" else "") ++ maybe "" (\e -> " throws(" ++ e ++ ")") failure ++
  (if result == "Void" then "" else " -> " ++ result)

-- | A declaration's function in its unit's generated enum.
entryFunctionIn :: [C.Unit] -> C.Declaration -> String
entryFunctionIn units d = maybe (functionName d) entryName (lookup (C.declarationId d) (entries units))

-- | Whether a unit has a generated enum: entries or handler factories.
hasModule :: C.Unit -> Bool
hasModule u = not (null (C.unitDeclarations u) && null (C.unitHandlers u) &&
  null [a | a <- N.ownAbilities u, not (C.isFail (C.abilityInstance a))])

-- | A typed definition's function and whether it takes the handler context.
type TypedCall = C.Id -> Maybe (String, Bool)

emitEntries :: D.Layout -> Int -> Calls -> TypedCall -> [C.DataDeclaration] -> [C.Unit] -> Either String [Artifact]
emitEntries layout bits calls typedCall declarations units = emitEntriesWithLayouts [] layout bits calls typedCall declarations units

emitEntriesWithLayouts :: [ResolvedTypeBinding] -> D.Layout -> Int -> Calls -> TypedCall -> [C.DataDeclaration] -> [C.Unit] -> Either String [Artifact]
emitEntriesWithLayouts bindings layout bits calls typedCall declarations units = do
  verified <- checkedDefinitionContracts bits declarations units
  names <- dataNames declarations
  forM [u | u <- orderedUnits units, hasModule u] $ \u -> do
    entryDocs <- mapM (entry names verified u) (C.unitDeclarations u)
    factories <- Abilities.unitFactories bits declarations units u
    let functions = entryDocs ++ factories
        enumName = last (splitDots (generatedName (C.unitId u)))
        doc = fileHeader (generatedHeader (unitSourceFile u)) [["import LawSpecRuntime"]] <> D.hardline <>
          D.text "extension LawSpec.Generated {" <> D.nest 2 (D.hardline <>
            D.text ("/// The entries of " ++ C.idText (C.unitId u) ++ ", on portable values.") <> D.hardline <>
            D.text ("public enum " ++ enumName ++ " {") <> D.nest 2 (D.hardline <>
              D.joinWith (D.hardline <> D.hardline) functions) <> D.hardline <> D.text "}") <> D.hardline <>
          D.text "}" <> D.hardline
    pure (Artifact ("src/LawSpec/Generated/" ++ enumName ++ "Entries.swift") (D.render layout doc) "generated" "source")
  where
    definitions = [(C.declarationId (C.definitionDeclaration d), d) | u <- units, d <- C.unitDefinitions u]
    entryFunction = entryFunctionIn units
    entry names verified unit declaration = do
      let identity = C.declarationId declaration
          (parameterTypes, resultType) = C.functionType (C.declarationType declaration)
          definition = lookup identity definitions
          -- A definition's arguments keep their source names; an adapter's
          -- have none, so they are numbered.
          arguments = case definition of
            Just d | length (C.definitionArguments d) == length parameterTypes ->
              fst (claimAll (scopeWith reservedLocals) [localName (C.binderName b) | b <- C.definitionArguments d])
            _ -> ["argument" ++ show i | (i, _) <- zip [0 :: Int ..] parameterTypes]
          locals = maybe [] (\d -> zip (map C.binderId (C.definitionArguments d)) arguments) definition
          resolve table variable = maybe (error ("unbound Swift binder: " ++ C.idText variable)) id (lookup variable table)
          context table = X.Context bits X.schemaVar X.symbolsVar (resolve table) (Effects.external units) X.typeRef X.typeKeyOf
          render table = X.render (context table)
      body <- case definition of
        -- A typed definition runs typed: its arguments to native values, and
        -- its result back.
        Just _ | Just (function, contextual) <- typedCall identity -> do
          parameterCodecs <- mapM (Data.codec bits names []) parameterTypes
          resultCodec <- Data.codec bits names [] resultType
          let natives = [Call (c ++ ".toNative") [Var a] | (c, a) <- zip parameterCodecs arguments]
              handlerContext = if contextual then [X.schemaVar, X.symbolsVar] else []
          pure (Call (resultCodec ++ ".fromNative") [Call function (handlerContext ++ natives)])
        Just d -> render locals (C.definitionBody d) >>= Policy.wrapDefinition units X.schemaVar X.symbolsVar (map Var arguments) d
        Nothing -> adapterCall names unit declaration arguments parameterTypes resultType
      let candidates = case definition of Just _ -> verified; Nothing -> C.unitContracts unit
          contracts = [c | c <- candidates, C.contractDeclaration c == identity]
      pre <- fmap concat $ forM contracts $ \c -> do
        let aliases = zip (map C.binderId (C.contractArguments c)) arguments
        mapM (fmap (\v -> call "Runtime" "require" [v, Str "precondition"]) . render aliases) (C.contractPreconditions c)
      post <- fmap concat $ forM contracts $ \c -> do
        let aliases = zip (map C.binderId (C.contractArguments c)) arguments ++ [(C.binderId (C.contractResult c), "result")]
        mapM (fmap (\v -> call "Runtime" "require" [v, Str "postcondition"]) . render aliases)
          (case definition of Just _ -> runtimePostconditions c; Nothing -> C.contractPostconditions c ++ C.contractRuntimePostconditions c)
      validated <- forM [(argument,ty) | (argument,ty) <- zip arguments parameterTypes,
        usesNativeLayout declarations bindings ty] $ \(argument,ty) -> do
          reference <- X.typeRef ty
          pure (argument, call "Schema" "validate" [Var argument, reference, X.schemaVar])
      let inner = foldr (\(argument,value) rest -> Let argument tValue value rest)
            (Do pre (Let "result" tValue body (Do post (Var "result")))) validated
          wrapped = call "Runtime" "contextual" [Str (C.idText identity), Lambda [] tValue inner]
          params = ["_ schema: Schema", "_ symbols: SymbolContext"] ++ ["_ " ++ a ++ ": Value" | a <- arguments]
      pure (sourceDoc (Naming.sourceDefinitionName (C.declarationName declaration)) (C.declarationOrigin declaration) <>
        signature ("public static func " ++ entryFunction declaration) params " throws -> Value" (renderBody tValue wrapped))
    -- The call of an adapter: its arguments to native values, the call, a
    -- typed failure raised as the logical one, and the result back, checked.
    adapterCall names unit declaration arguments parameterTypes resultType = do
      parameterCodecs <- mapM (Data.codec bits names []) parameterTypes
      resultCodec <- Data.codec bits names [] resultType
      resultRef <- X.typeRef resultType
      (_, nativeResult, failure, async) <- nativeSignature bits names units declaration
      handlers <- forM (Effects.uses declaration) $ \ref -> do
        a <- maybe (Left ("unknown Swift ability " ++ C.abilityKey ref)) Right (N.abilityOf units ref)
        pure (Effects.bridgeCall a "ToNative" [X.schemaVar, X.symbolsVar, call "Effects" "handler" [X.schemaVar, Str (C.abilityKey ref)]])
      failureCodec <- traverse (Data.codec bits names []) (declarationFailure declaration)
      let valueNatives = [(c, a) | (c, a, t) <- zip3 parameterCodecs arguments parameterTypes, not (isUnit t)]
          handlerNames = ["handler" ++ show i | (i, _) <- zip [0 :: Int ..] handlers]
          valueNames = ["native" ++ show i | (i, _) <- zip [0 :: Int ..] valueNatives]
          nativeNames = handlerNames ++ valueNames
          bindings = zip nativeNames (handlers ++ [Call (c ++ ".toNative") [Var a] | (c, a) <- valueNatives])
          adapter = unitQualified (C.unitId unit) ++ "." ++ functionName declaration
          voidResult = nativeResult == "Void"
          resultTy = if voidResult then "Void" else nativeResult
          key = failureKey declaration
          convert fc = Code (closureDoc ("(failure: " ++ maybe "" id failure ++ ") throws -> Value") (callDoc ("try " ++ fc ++ ".fromNative") [D.text "failure"]))
          adapterInvocation = callDoc adapter (map D.text nativeNames)
          bound = lookup (C.declarationId declaration) calls
          refText = intercalate "." . referenceParts
          -- Application code bound in lawspec.json: a function, a type's
          -- initializer, or a method of the first argument.
          boundCallee = case bound of
            Just (StaticCall ref) -> Just (refText ref, nativeNames)
            Just (ConstructorCall ref) -> Just (refText ref ++ ".init", nativeNames)
            Just (MethodCall method) -> case valueNames of
              receiver : rest -> Just (receiver ++ "." ++ method, handlerNames ++ rest)
              [] -> Nothing
            Nothing -> Nothing
          invocation = case (boundCallee, failure, failureCodec, async) of
            (Just (callee, args), _, _, False) -> Call "Effects.bound" (Raw callee : map Var args)
            (Just (callee, args), _, _, True) ->
              Call "Runtime.awaitBoxed" [Pure "UncheckedBox" [Code (closureDoc ("() async throws -> " ++ resultTy)
                (callDoc "try await Effects.boundAsync" (map D.text (callee : args))))]]
            (Nothing, Just e, Just fc, False) ->
              Call "Effects.ofThrown" [Str key, convert fc, Code (closureDoc ("() throws(" ++ e ++ ") -> " ++ resultTy) (D.text "try " <> adapterInvocation))]
            (Nothing, Just e, Just fc, True) ->
              Call "Runtime.awaitBoxed" [Pure "UncheckedBox" [Code (closureDoc ("() async throws -> " ++ resultTy)
                (D.text ("do throws(" ++ e ++ ")") <> blockDoc (hangValue "return" (D.text "try await " <> adapterInvocation)) <>
                 D.text " catch" <> blockDoc (callDoc "throw RaisedFailure" [D.text (stringLiteral key), callDoc ("try " ++ fc ++ ".fromNative") [D.text "error"]])))]]
            (Nothing, _, _, True) -> Call "Runtime.awaitBoxed" [Pure "UncheckedBox" [Code (closureDoc ("() async throws -> " ++ resultTy) (D.text "await " <> adapterInvocation))]]
            _ -> Pure adapter (map Var nativeNames)
          converted = if voidResult then Do [Statement invocation] (Raw "Value.unit") else Call (resultCodec ++ ".fromNative") [invocation]
      -- A bound function fails by throwing: its declared failure type, or
      -- an error lawspec.json maps to one of its constructors.
      mapped <- case (bound, declarationFailure declaration, failure, failureCodec) of
        (Just _, Just failureTy, Just e, Just fc) -> do
          ref <- X.typeRef failureTy
          let own = Code (callDoc "Effects.mapError" [D.text (e ++ ".self")] <> D.text " " <>
                closureDoc ("(failure: " ++ e ++ ") throws -> Value") (callDoc ("try " ++ fc ++ ".fromNative") [D.text "failure"]))
              mapping (k, fb) =
                let native = intercalate "." (C.failureNative fb)
                    caught = "caught" ++ show (k :: Int)
                    fields = arrayDoc (C.mapFailureFields
                      (\ty tag values -> callDoc "try Schema.construct" [D.text (stringLiteral (C.idText tag)), arrayDoc values,
                        renderExpr (either error id (X.typeRef ty)), D.text "schema"])
                      (D.text ("Value.text(String(describing: " ++ caught ++ "))")) fb)
                in Code (callDoc "Effects.mapError" [D.text (native ++ ".self")] <> D.text " " <>
                     closureDoc ("(" ++ caught ++ ": " ++ native ++ ") throws -> Value")
                       (callDoc "try Schema.construct" [D.text (stringLiteral (C.idText (C.failureConstructor fb))), fields,
                         renderExpr ref, D.text "schema"]))
              mappings = map mapping (zip [0 ..] [fb | fb <- C.unitFailureBindings unit, C.failureType fb == failureTy])
          pure (call "Effects" "nativeFailures" [Str key, Lambda [] tValue converted, ListOf (Ty "[(any Error) throws -> Value?]") (mappings ++ [own])])
        _ -> pure converted
      let made = foldr (\(n, v) rest -> Let n (Ty "") v rest) mapped bindings
      pure (call "Schema" "validate" [made, resultRef, X.schemaVar])

-- | The enum of a unit's checked definitions on native values.
-- | Each unit's checked definitions on native values: the embedding API
-- applications call. A definition that uses abilities takes their native
-- handlers first; one that can fail throws its failure.
-- ref:DEC-typed-native-definitions ref:DEC-native-bindings-typed-identity
emitApi :: D.Layout -> Int -> [C.DataDeclaration] -> [C.Unit] -> Either String [Artifact]
emitApi layout bits declarations units = do
  names <- dataNames declarations
  fmap concat $ forM [u | u <- orderedUnits units, not (null (C.unitDefinitions u))] $ \u -> do
    functions <- forM (C.unitDefinitions u) $ \definition -> do
      let d = C.definitionDeclaration definition
          (parameterTypes, resultType) = C.functionType (C.declarationType d)
      handlers <- forM (Effects.uses d) $ \ref -> maybe (Left ("unknown Swift ability " ++ C.abilityKey ref)) Right (N.abilityOf units ref)
      (params, r, failure, async) <- nativeSignature bits names units d
      codecs <- mapM (Data.codec bits names []) parameterTypes
      out <- Data.codec bits names [] resultType
      failureCodec <- traverse (Data.codec bits names []) (declarationFailure d)
      e <- maybe (Left "missing Swift entry") Right (lookup (C.declarationId d) (entries units))
      let valueParams = drop (length handlers) params
          valueArguments = go codecs parameterTypes (map fst valueParams)
            where go (c : cs) (t : ts) ns
                    | isUnit t = Raw "Value.unit" : go cs ts ns
                    | (n : rest) <- ns = Call (c ++ ".fromNative") [Var n] : go cs ts rest
                  go _ _ _ = []
          void = r == "Void"
          resultTy = Ty (if void then "Void" else r)
          scopeName = if null handlers then "schema" else "scope"
          entryCall = Call (entryOwner e ++ "." ++ entryName e) (Var scopeName : Var "symbols" : valueArguments)
          converted = if void then entryCall else Call (out ++ ".toNative") [entryCall]
          -- The handlers given, as the logical handlers of their abilities.
          scoped = if null handlers then converted else
            Call "Effects.withScope" [Var "schema",
              ListOf (Ty "[(String, (Schema) throws -> Effects.Handler)]")
                [ TupleOf [Str (C.abilityKey (C.abilityInstance a)), Lambda [("scope", tSchema)] Effects.handlerTy
                    (Call ("LawSpec.AbilityBridges." ++ Effects.bridgeName a "FromNative") [Var "scope", Var "symbols", Var n])]
                | (a, (n, _)) <- zip handlers params ],
              Lambda [("scope", tSchema)] resultTy converted]
          body = Lambda [] resultTy (Let "schema" (Ty "") (Raw "LawSpec.Program.schema")
            (Let "symbols" (Ty "") (Raw "SymbolContext()") scoped))
          toNative fc = Raw ("{ try " ++ fc ++ ".toNative($0) }")
          runner = case (failure, failureCodec, async) of
            (Just _, Just fc, False) -> Call "Embedding.runFailing" [Str (failureKey d), toNative fc, body]
            (Just _, Just fc, True) -> Call "await Embedding.runFailingAsync" [Str (failureKey d), toNative fc, Pure "UncheckedBox" [body]]
            (_, _, True) -> Pure "await Embedding.runAsync" [Pure "UncheckedBox" [body]]
            _ -> Pure "Embedding.run" [body]
      pure (sourceDoc (Naming.sourceDefinitionName (C.declarationName d)) (C.declarationOrigin d) <>
        signatureDoc "public static func" (entryName e) params r failure async
          (if void then renderStatements (Statement runner) else renderBody resultTy runner))
    let enumName = last (splitDots (apiName (C.unitId u)))
        doc = fileHeader (generatedHeader (unitSourceFile u)) [["import LawSpecRuntime"]] <> D.hardline <>
          D.text "extension LawSpec.Definitions {" <> D.nest 2 (D.hardline <>
            D.text ("/// The checked definitions of " ++ C.idText (C.unitId u) ++ ", on native values.") <> D.hardline <>
            D.text ("public enum " ++ enumName ++ " {") <> D.nest 2 (D.hardline <>
              D.joinWith (D.hardline <> D.hardline) functions) <> D.hardline <> D.text "}") <> D.hardline <>
          D.text "}" <> D.hardline
    pure [Artifact ("src/LawSpec/Definitions/" ++ enumName ++ "Definitions.swift") (D.render layout doc) "generated" "source"]

-- | Each unit's adapter: a stub for every declaration it must implement.
emitAdapters :: D.Layout -> Int -> Calls -> [C.DataDeclaration] -> [C.Unit] -> Either String [Artifact]
emitAdapters layout bits calls declarations units = do
  names <- dataNames declarations
  forM [u | u <- orderedUnits units, not (null (unbound u)) || not (null (productionAbilities u))] $ \u -> do
    stubs <- Abilities.productionStubs bits declarations u
    functions <- fmap (++ stubs) $ forM (unbound u) $ \d -> do
      (params, r, failure, async) <- nativeSignature bits names units d
      let message = "not implemented: " ++ C.idText (C.declarationId d)
      pure (sourceDoc (Naming.sourceDefinitionName (C.declarationName d) ++ " :: " ++ topType (C.declarationType d)) (C.declarationOrigin d) <>
        signatureDoc "static func" (functionName d) params r failure async (callDoc "fatalError" [D.text (stringLiteral message)]))
    let doc = fileHeader "User-owned LawSpec adapter. Implement these functions." [["import LawSpecRuntime"]] <> D.hardline <>
          D.text ("extension " ++ unitQualified (C.unitId u) ++ " {") <> D.nest 2 (D.hardline <>
            D.joinWith (D.hardline <> D.hardline) functions) <> D.hardline <> D.text "}" <> D.hardline
    pure (AdapterArtifact (adapterPath (C.unitId u)) (D.render layout doc) "user" "source" (D.render swiftLayout doc))
  where
    unbound u = [d | d <- adapterDeclarations u, lookup (C.declarationId d) calls == Nothing]
    productionAbilities u = [a | a <- N.ownAbilities u, not (C.isFail (C.abilityInstance a)), C.abilityNative a == Nothing, not (Effects.hasDefault a)]
    -- A signature's type as it is written: its arrow without parentheses.
    topType t = case t of
      C.Arrow a b -> showType a ++ " -> " ++ topType b
      _ -> showType t
    showType t = case t of
      C.Arrow a b -> "(" ++ showType a ++ " -> " ++ showType b ++ ")"
      C.Constructor n [] -> n
      C.Constructor n args -> n ++ concat [" (" ++ arg a ++ ")" | a <- args]
      C.TypeVariable v -> C.idText v
    arg (C.TypeArgument t) = showType t
    arg (C.IndexArgument _) = "_"
