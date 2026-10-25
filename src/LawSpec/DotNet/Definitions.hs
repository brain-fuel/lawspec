-- | Each unit's entries on .NET: its checked definitions, evaluated on
-- portable values, and a bridge to each adapter that converts values to the
-- adapter's native types and back, checking contracts on the way. Tests,
-- definitions and the embedding API all call these same entries.
-- ref:DEC-total-definitions ref:DEC-native-bindings-typed-identity
module LawSpec.DotNet.Definitions
  ( Entry(..), entries, entryCall, orderedUnits, emitEntries, emitEntriesWithLayouts, emitAdapters, adapterDeclarations
  , nativeSignature, emitApi, apiModule, csUsingLines, TypedCall
  ) where

import qualified LawSpec.Core as C
import LawSpec.SourceLink (generatedHeader, unitSourceFile, labelled, sourceLink)
import LawSpec.Naming (sourceDefinitionName)
import qualified LawSpec.Code.Doc as D
import LawSpec.Core.DefinitionContracts (checkedDefinitionContracts)
import LawSpec.Core.Evidence (runtimePostconditions)
import LawSpec.Common (Artifact(..))
import LawSpec.DotNet.Code
import qualified LawSpec.DotNet.Layout as L
import LawSpec.DotNet.Names
import qualified LawSpec.DotNet.Data as Data
import qualified LawSpec.DotNet.Expr as X
import LawSpec.DotNet.Entries
import qualified LawSpec.DotNet.Effects as Effects
import qualified LawSpec.DotNet.Abilities as Abilities
import qualified LawSpec.DotNet.Policy as Policy
import qualified LawSpec.AbilityNames as N
import LawSpec.NativeBinding (NativeRef(..), ResolvedTypeBinding, usesNativeLayout)
import LawSpec.NativeRequest (NativeCall(..))
import Control.Monad (forM)
import Data.List (intercalate)

-- | A definition's displayed name and source link belong to its source,
-- including when the checked body is a monomorphic specialization.
definitionLabel :: C.Declaration -> String
definitionLabel d = labelled (sourceDefinitionName (C.declarationName d)) (sourceLink (C.declarationOrigin d))

-- | A source label in an XML documentation summary is text, never markup.
xmlComment :: String -> String
xmlComment = concatMap (\c -> case c of '&' -> "&amp;"; '<' -> "&lt;"; '>' -> "&gt;"; _ -> [c])

-- | The adapters bound in lawspec.edn to application code, by declaration.
type Calls = [(C.Id, NativeCall)]

-- | The declarations a unit's adapter implements: those that are not definitions.
adapterDeclarations :: C.Unit -> [C.Declaration]
adapterDeclarations u = [d | d <- C.unitDeclarations u,
  C.declarationId d `notElem` map (C.declarationId . C.definitionDeclaration) (C.unitDefinitions u)]

-- | An adapter's native parameter and result types.
nativeSignature :: Lang -> Int -> Data.Names -> [C.Unit] -> C.Declaration -> Either String ([String], String)
nativeSignature lang bits names units d = do
  let (parameters, result) = C.functionType (C.declarationType d)
  handlers <- mapM (Effects.interfaceTypeOf units) (Effects.uses d)
  ps <- mapM (Data.nativeType lang bits names []) [p | p <- parameters, not (csUnit lang p)]
  r <- Data.nativeType lang bits names [] result
  failure <- traverse (Data.nativeType lang bits names []) (declarationFailure d)
  let returned = Abilities.nativeResult lang r failure
      -- A C# adapter takes no Unit argument and returns void for Unit.
      voidResult = csUnit lang result && failure == Nothing
  pure (handlers ++ ps, case (C.declarationAsync d, voidResult) of
    (True, True) -> "Task"
    (True, False) -> task returned
    (False, True) -> "void"
    (False, False) -> returned)
  where task r = case lang of
          FSharp -> "System.Threading.Tasks.Task<" ++ r ++ ">"
          CSharp -> "Task<" ++ r ++ ">"

-- | Unit, which C# adapters leave out of their arguments and results.
csUnit :: Lang -> C.Type -> Bool
csUnit CSharp t = t == C.Constructor "Unit" []
csUnit FSharp _ = False

-- | The failure type of a declaration that fails with one.
declarationFailure :: C.Declaration -> Maybe C.Type
declarationFailure d = case [f | C.AbilityRef _ [f] <- filter C.isFail (C.declarationUses d)] of
  f : _ -> Just f
  [] -> Nothing

failureKey :: C.Declaration -> String
failureKey d = case filter C.isFail (C.declarationUses d) of
  ref : _ -> C.abilityKey ref
  [] -> ""

-- | Whether a unit has a generated module: entries or handler factories.
hasModule :: C.Unit -> Bool
hasModule u = not (null (C.unitDeclarations u) && null (C.unitHandlers u) &&
  null [a | a <- N.ownAbilities u, not (C.isFail (C.abilityInstance a))])

-- | One generated module per unit, holding its entries.
-- | A typed definition's function (F# and C# names) and whether it takes the
-- handler context.
type TypedCall = C.Id -> Maybe (String, String, Bool)

emitEntries :: Lang -> D.Layout -> Int -> Calls -> TypedCall -> [C.DataDeclaration] -> [C.Unit] -> Either String [Artifact]
emitEntries lang layout bits calls typedCall declarations units = emitEntriesWithLayouts [] lang layout bits calls typedCall declarations units

emitEntriesWithLayouts :: [ResolvedTypeBinding] -> Lang -> D.Layout -> Int -> Calls -> TypedCall -> [C.DataDeclaration] -> [C.Unit] -> Either String [Artifact]
emitEntriesWithLayouts bindings lang layout bits calls typedCall declarations units = do
  verified <- checkedDefinitionContracts bits declarations units
  names <- dataNames declarations
  forM [u | u <- orderedUnits units, hasModule u] $ \u -> do
    entryDocs <- mapM (entry names verified u) (C.unitDeclarations u)
    factories <- Abilities.unitFactories lang bits declarations units u
    let functions = entryDocs ++ factories
    let moduleName = generatedModule (C.unitId u)
        doc = case lang of
          FSharp -> D.text ("// " ++ generatedHeader (unitSourceFile u)) <> D.hardline <>
            D.text ("/// The entries of " ++ C.idText (C.unitId u) ++ ", on portable values.") <> D.hardline <>
            D.text ("module rec " ++ moduleName) <> D.hardline <> D.hardline <>
            D.text "open LawSpec.Runtime" <> D.hardline <>
            (if null functions then mempty else D.hardline <> D.joinWith (D.hardline <> D.hardline) functions <> D.hardline)
          CSharp -> D.text ("// " ++ generatedHeader (unitSourceFile u)) <> D.hardline <>
            D.text ("namespace " ++ namespaceOf moduleName ++ ";") <> D.hardline <> D.hardline <> csUsings <> D.hardline <>
            D.text ("/// <summary>The entries of " ++ C.idText (C.unitId u) ++ ", on portable values.</summary>") <> D.hardline <>
            D.text ("public static class " ++ lastOf moduleName) <> D.hardline <>
            D.block 4 (D.joinWith (D.hardline <> D.hardline) functions) <> D.hardline
    pure (Artifact ("src/LawSpec/Generated/" ++ lastOf moduleName ++ extension lang) (D.render layout doc) "generated" "source")
  where
    definitions = [(C.declarationId (C.definitionDeclaration d), d) | u <- units, d <- C.unitDefinitions u]
    entry names verified unit declaration = do
      let identity = C.declarationId declaration
          (parameterTypes, resultType) = C.functionType (C.declarationType declaration)
          definition = lookup identity definitions
          -- A definition's parameters keep their source names; an adapter's
          -- declaration has none of its own.
          arguments = case definition of
            Just d | length (C.definitionArguments d) == length parameterTypes ->
              localNames lang ["schema", "symbols", "result", "receiver"] (map C.binderName (C.definitionArguments d))
            _ -> ["argument" ++ show i | (i, _) <- zip [0 :: Int ..] parameterTypes]
          locals = maybe [] (\d -> zip (map C.binderId (C.definitionArguments d)) arguments) definition
          resolve table variable = maybe (error ("unbound .NET binder: " ++ C.idText variable)) id (lookup variable table)
          context table = X.Context bits X.schemaVar X.symbolsVar (resolve table) (Effects.external units) X.typeRef X.typeKeyOf
          render table = X.render (context table)
      body <- case definition of
        -- A typed definition runs typed: its arguments to native values, and
        -- its result back.
        Just _ | Just (fsName, csName, contextual) <- typedCall identity -> do
          parameterCodecs <- mapM (Data.codec lang bits names []) parameterTypes
          resultCodec <- Data.codec lang bits names [] resultType
          let natives = [codecCall c "ToNative" [Var a] | (c, a) <- zip parameterCodecs arguments]
              handlerContext = if contextual then [X.schemaVar, X.symbolsVar] else []
              invocation = Call (Fn fsName csName) (handlerContext ++ (if null natives && not contextual && lang == FSharp then [UnitLit] else natives))
          -- C# sees an F# function returning unit as a void method.
          pure (if lang == CSharp && resultType == C.Constructor "Unit" []
            then Do [invocation] (Raw "Value.Unit" "V.Unit")
            else codecCall resultCodec "FromNative" [invocation])
        Just d -> render locals (C.definitionBody d) >>= Policy.wrapDefinition units X.schemaVar X.symbolsVar (map Var arguments) d
        Nothing -> do
          parameterCodecs <- mapM (Data.codec lang bits names []) parameterTypes
          resultCodec <- Data.codec lang bits names [] resultType
          resultRef <- X.typeRef resultType
          handlers <- forM (Effects.uses declaration) $ \ref -> do
            a <- maybe (Left ("unknown .NET ability " ++ C.abilityKey ref)) Right (N.abilityOf units ref)
            pure (Effects.bridgeCall a "ToNative" [X.schemaVar, X.symbolsVar, call "Effects" "handler" [X.schemaVar, Str (C.abilityKey ref)]])
          failureCodec <- traverse (Data.codec lang bits names []) (declarationFailure declaration)
          parameterNatives <- mapM (Data.nativeType lang bits names []) [t | t <- parameterTypes, not (csUnit lang t)]
          let natives = handlers ++ [codecCall c "ToNative" [Var a] | (c, a, t) <- zip3 parameterCodecs arguments parameterTypes, not (csUnit lang t)]
              valueNatives = drop (length handlers) natives
              bound = lookup identity calls
              adapter = case bound of
                Nothing -> Call (Fn (unitQualified (C.unitId unit) ++ "." ++ functionName FSharp declaration)
                  (unitQualified (C.unitId unit) ++ "." ++ functionName CSharp declaration)) natives
                Just (StaticCall ref) -> Call (Fn (refText ref) (refText ref)) natives
                Just (ConstructorCall ref) -> Ctor (Fn (refText ref) ("new " ++ refText ref)) (handlers ++ nonUnit valueNatives)
                Just (MethodCall method) -> case valueNatives of
                  receiver : rest -> Let "receiver" (Ty (head parameterNatives) (head parameterNatives)) receiver
                    -- C# sees a handle as an object, so its methods are found when called.
                    (Ctor (Fn ("receiver." ++ pascalMethod method) ("((dynamic)receiver)." ++ pascalMethod method)) (handlers ++ rest))
                  [] -> Raw "invalidOp \"a method binding needs a receiver\"" "throw new InvalidOperationException()"
              nonUnit xs = [x | (x, t) <- zip xs [t' | t' <- parameterTypes, not (csUnit lang t')], t /= C.Constructor "Unit" []]
              voidResult = csUnit lang resultType && failureCodec == Nothing
              awaited = case (C.declarationAsync declaration, voidResult) of
                (True, True) -> Do [call "Runtime" "awaitDone" [adapter]] UnitLit
                (True, False) -> call "Runtime" "await" [adapter]
                (False, True) -> Do [adapter] UnitLit
                (False, False) -> adapter
              succeeded = case (failureCodec, bound) of
                (Just fc, Nothing) -> call "Effects" "ofResult" [Str (failureKey declaration), Raw ("(" ++ fc ++ ".FromNative)") ("(" ++ fc ++ ".FromNative)"), awaited]
                _ -> awaited
              converted = codecCall resultCodec "FromNative" [succeeded]
          mapped <- case declarationFailure declaration of
            Nothing -> pure converted
            Just failureTy -> do
              let bindings = [fb | fb <- C.unitFailureBindings unit, C.failureType fb == failureTy]
              if null bindings then pure converted else do
                ref <- X.typeRef failureTy
                let mapping (k, fb) = let caught = "caught" ++ show (k :: Int) in Call (Fn ("Effects.mapException<" ++ intercalate "." (C.failureNative fb) ++ ">")
                      ("Effects.MapException<" ++ intercalate "." (C.failureNative fb) ++ ">"))
                      [Lambda [(caught, Ty (intercalate "." (C.failureNative fb)) (intercalate "." (C.failureNative fb)))] tValue
                        (call "Schema" "construct" [Str (C.idText (C.failureConstructor fb)),
                          ListOf tValue (C.mapFailureFields (\ty tag fields -> call "Schema" "construct" [Str (C.idText tag), ListOf tValue fields, either error id (X.typeRef ty), X.schemaVar]) (Ctor (Fn "Value.Text" "V.Text") [Raw (caught ++ ".Message") (caught ++ ".Message")]) fb), ref, X.schemaVar])]
                pure (call "Effects" "nativeFailures" [Str (failureKey declaration), Lambda [] tValue converted,
                  ListOf (Ty "(exn -> Value option)" "FSharpFunc<Exception, FSharpOption<Value>>") (map mapping (zip [0 ..] bindings))])
          pure (call "Schema" "validate" [mapped, resultRef, X.schemaVar])
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
            (Do pre (if null post then body else Let "result" tValue body (Do post (Var "result")))) validated
          wrapped = call "Runtime" "contextual" [Str (C.idText identity), Lambda [] tValue inner]
          name = functionName lang declaration
          params = [("schema", tSchema), ("symbols", tSymbols)] ++ [(a, tValue) | a <- arguments]
          comment = "/// " ++ definitionLabel declaration
      pure $ case lang of
        FSharp -> D.text comment <> D.hardline <> linesDoc 0 (functionLines FSharp 0 ("let " ++ name) params tValue wrapped)
        CSharp -> D.text ("/// <summary>" ++ xmlComment (definitionLabel declaration) ++ "</summary>") <> D.hardline <>
          linesDoc 4 (functionLines CSharp 4 ("public static Value " ++ name) params tValue wrapped)
    -- A codec built by an expression is applied through Codec.toNative and
    -- Codec.fromNative in F#, as Fantomas lays out an application.
    codecCall c member args
      | lang == FSharp, take 1 c == "(" = Call (Fn ("Codec." ++ lowerFirst member) (c ++ "." ++ member ++ ".Invoke")) (Raw c c : args)
      | otherwise = Call (Fn (c ++ "." ++ member) (c ++ "." ++ member ++ ".Invoke")) args
    lowerFirst (x : xs) = toEnum (fromEnum x + (if x >= 'A' && x <= 'Z' then 32 else 0)) : xs
    lowerFirst [] = []
    refText = intercalate "." . referenceParts
    -- A bound method keeps its name when it is already one .NET would write.
    pascalMethod m = m
    namespaceOf m = intercalate "." (init (splitDots m))
    lastOf m = last (splitDots m)

-- | The module of a unit's checked definitions on native values.
-- One flat module per unit, so a unit and a unit inside it never make a
-- module and a namespace of the same name.
apiModule :: C.Id -> String
apiModule identity = "LawSpec.Definitions." ++ concatMap pascal (splitDots (C.idText identity))

-- | Each unit's checked definitions on native values: the embedding API
-- applications call. A definition that uses abilities takes their native
-- handlers first; one that can fail returns a Result.
-- ref:DEC-typed-native-definitions ref:DEC-native-bindings-typed-identity
emitApi :: Lang -> D.Layout -> Int -> [C.DataDeclaration] -> [C.Unit] -> Either String [Artifact]
emitApi FSharp layout bits declarations units = do
  names <- dataNames declarations
  fmap concat $ forM [u | u <- orderedUnits units, not (null (C.unitDefinitions u))] $ \u -> do
    functions <- forM (C.unitDefinitions u) $ \definition -> do
      let d = C.definitionDeclaration definition
          (parameterTypes, resultType) = C.functionType (C.declarationType d)
      handlers <- forM (Effects.uses d) $ \ref -> do
        a <- maybe (Left ("unknown .NET ability " ++ C.abilityKey ref)) Right (N.abilityOf units ref)
        pure (a, camel (N.interfaceName a))
      -- Parameters keep their source names.
      let arguments = localNames FSharp (["schema", "symbols", "s"] ++ map snd handlers) (map C.binderName (C.definitionArguments definition))
      (ps, r) <- nativeSignature FSharp bits names units d
      codecs <- mapM (Data.codec FSharp bits names []) parameterTypes
      out <- Data.codec FSharp bits names [] resultType
      failure <- traverse (Data.codec FSharp bits names []) (declarationFailure d)
      e <- maybe (Left "missing .NET entry") Right (lookup (C.declarationId d) (entries units))
      let params = [(n, t) | ((_, n), t) <- zip handlers ps] ++ zip arguments (drop (length handlers) ps)
          -- A codec built by an expression is applied through Codec.toNative
          -- and Codec.fromNative, as Fantomas lays out an application.
          convert c member x
            | take 1 c == "(" = L.App ("Codec." ++ member) [L.A c, x]
            | otherwise = L.App (c ++ "." ++ capitalised member) [x]
          capitalised (x : xs) = toEnum (fromEnum x - (if x >= 'a' && x <= 'z' then 32 else 0)) : xs
          capitalised [] = []
          call' = L.App (entryModule e ++ "." ++ entryFs e) ([L.A "schema", L.A "symbols"] ++ [convert c "fromNative" (L.A a) | (c, a) <- zip codecs arguments])
          converted = convert out "toNative" call'
          checked = case failure of
            Nothing -> converted
            Just fc -> L.App "Effects.nativeTry" [L.A (stringLiteral FSharp (failureKey d)), if take 1 fc == "(" then L.App "Codec.toNative" [L.A fc] else L.A (fc ++ ".ToNative"), L.Fun "()" converted]
          scoped = asTask (if null handlers then checked else
            L.App "Effects.withScope" [L.A "schema", L.List
                [L.Tuple [L.A (stringLiteral FSharp (C.abilityKey (C.abilityInstance a))), L.Fun "s" (L.App ("LawSpec.Generated.Abilities." ++
                  Effects.bridgeName a "FromNative") [L.A "s", L.A "symbols", L.A n])] | (a, n) <- handlers],
              L.Fun "schema" checked])
          -- An async definition runs on the thread pool; its entries are
          -- synchronous inside, awaiting their adapters.
          asTask body
            | C.declarationAsync d = L.Method "System.Threading.Tasks.Task.Run<_>" [L.Method "System.Func<_>" [L.Fun "()" body]]
            | otherwise = body
          setup = [L.LetS "let schema" (L.A "LawSpec.Generated.Program.schema"), L.LetS "let symbols" (L.A "Scalar.SymbolContext()")]
      pure (D.text ("/// " ++ definitionLabel d) <> D.hardline <>
        L.linesDoc 0 (L.function 0 ("let " ++ functionName FSharp d) (if null params then ["()"] else ["(" ++ n ++ ": " ++ t ++ ")" | (n, t) <- params]) (Just r)
          (L.Block setup scoped)))
    let moduleName = apiModule (C.unitId u)
        doc = D.text ("// " ++ generatedHeader (unitSourceFile u)) <> D.hardline <>
          D.text ("/// The checked definitions of " ++ C.idText (C.unitId u) ++ ", on native values.") <> D.hardline <>
          D.text ("module " ++ moduleName) <> D.hardline <> D.hardline <>
          D.text "open LawSpec.Runtime" <> D.hardline <> D.hardline <>
          D.joinWith (D.hardline <> D.hardline) functions <> D.hardline
    pure [Artifact ("src/LawSpec/Definitions/" ++ concatMap pascal (splitDots (C.idText (C.unitId u))) ++ ".fs") (D.render layout doc) "generated" "source"]
emitApi CSharp layout bits declarations units = do
  names <- dataNames declarations
  fmap concat $ forM [u | u <- orderedUnits units, not (null (C.unitDefinitions u))] $ \u -> do
    methods <- forM (C.unitDefinitions u) $ \definition -> do
      let d = C.definitionDeclaration definition
          (parameterTypes, resultType) = C.functionType (C.declarationType d)
      handlers <- forM (Effects.uses d) $ \ref -> do
        a <- maybe (Left ("unknown .NET ability " ++ C.abilityKey ref)) Right (N.abilityOf units ref)
        pure (a, camel (N.interfaceName a))
      -- Parameters keep their source names.
      let kept = zip parameterTypes (localNames CSharp (["schema", "symbols", "s"] ++ map snd handlers) (map C.binderName (C.definitionArguments definition)))
      (ps, r) <- nativeSignature CSharp bits names units d
      codecs <- mapM (Data.codec CSharp bits names []) parameterTypes
      out <- Data.codec CSharp bits names [] resultType
      failure <- traverse (Data.codec CSharp bits names []) (declarationFailure d)
      e <- maybe (Left "missing .NET entry") Right (lookup (C.declarationId d) (entries units))
      let valueParams = [(n, t) | ((ty, n), t) <- zip [k | k@(ty', _) <- kept, not (csUnit CSharp ty')] (drop (length handlers) ps), ty == ty]
          params = [(n, t) | ((_, n), t) <- zip handlers ps] ++ valueParams
          arguments = [if csUnit CSharp ty then "V.Unit" else c ++ ".FromNative.Invoke(" ++ n ++ ")" | ((ty, n), c) <- zip kept codecs]
          call' = entryModule e ++ "." ++ entryCs e ++ "(" ++ intercalate ", " ("schema" : "symbols" : arguments) ++ ")"
          isVoid = r == "void" || r == "Task"
          converted = if isVoid then call' else out ++ ".ToNative.Invoke(" ++ call' ++ ")"
          checked = case failure of
            Nothing -> converted
            Just fc -> "Effects.NativeTry(" ++ stringLiteral CSharp (failureKey d) ++ ", " ++ fc ++ ".ToNative, Fn.F0(() => " ++ converted ++ "))"
          scoped body = if null handlers then body else
            "Effects.WithScope(schema, Fn.List(" ++ intercalate ", "
              [ "Fn.Tuple(" ++ stringLiteral CSharp (C.abilityKey (C.abilityInstance a)) ++ ", Fn.F1((Schema.Schema s) => LawSpec.Generated.Abilities." ++
                  pascal (Effects.bridgeName a "FromNative") ++ "(s, symbols, " ++ n ++ ")))" | (a, n) <- handlers] ++
              "), Fn.F1((Schema.Schema schema) => " ++ body ++ "))"
          voidScoped = if null handlers then [converted ++ ";"]
            else [scoped ("{ " ++ converted ++ "; return default(Unit); }") ++ ";"]
          statements
            | isVoid = voidScoped
            | otherwise = ["return " ++ scoped checked ++ ";"]
          setup = ["var schema = LawSpec.Generated.Program.Schema;", "var symbols = new Scalar.SymbolContext();"]
          bodyLines
            | C.declarationAsync d && isVoid = ["return Task.Run(() =>", "{"] ++ map ("    " ++) (setup ++ statements) ++ ["});"]
            | C.declarationAsync d = ["return Task.Run(() =>", "{"] ++ map ("    " ++) (setup ++ statements) ++ ["});"]
            | otherwise = setup ++ statements
      pure (D.text ("/// <summary>" ++ xmlComment (definitionLabel d) ++ "</summary>") <> D.hardline <>
        D.text ("public static " ++ r ++ " " ++ functionName CSharp d ++ "(" ++ intercalate ", " [t ++ " " ++ n | (n, t) <- params] ++ ")") <> D.hardline <>
        D.block 4 (D.joinWith D.hardline (map D.text bodyLines)))
    -- One flat class per unit, so a unit and a unit inside it never make a
    -- class and a namespace of the same name.
    let moduleName = apiModule (C.unitId u)
        doc = D.text ("// " ++ generatedHeader (unitSourceFile u)) <> D.hardline <>
          D.text ("namespace " ++ intercalate "." (init (splitDots moduleName)) ++ ";") <> D.hardline <> D.hardline <>
          csUsings <> D.hardline <>
          D.text ("/// <summary>The checked definitions of " ++ C.idText (C.unitId u) ++ ", on native values.</summary>") <> D.hardline <>
          D.text ("public static class " ++ last (splitDots moduleName)) <> D.hardline <>
          D.block 4 (D.joinWith (D.hardline <> D.hardline) methods) <> D.hardline
    pure [Artifact ("src/LawSpec/Definitions/" ++ concatMap pascal (splitDots (C.idText (C.unitId u))) ++ ".cs") (D.render layout doc) "generated" "source"]

-- | A C# file's usings, written after its namespace so the aliases for the
-- runtime's modules (Runtime, Codecs) take precedence over the LawSpec.Runtime
-- namespace itself.
csUsings :: D.Doc
csUsings = D.joinWith D.hardline (map D.text csUsingLines) <> D.hardline

csUsingLines :: [String]
csUsingLines =
  adapterUsingLines ++ [ "using LawSpec.Runtime;", "using Runtime = LawSpec.Runtime.Runtime;", "using Codecs = LawSpec.Runtime.Codec;", "using Value = LawSpec.Runtime.Value;" ]

-- | A C# adapter's usings: F#'s collections and options, and the
-- compatibility layer's helpers.
adapterUsingLines :: [String]
adapterUsingLines =
  [ "using System;", "using System.Collections.Generic;", "using System.Numerics;", "using System.Threading.Tasks;"
  , "using Microsoft.FSharp.Core;", "using Microsoft.FSharp.Collections;", "using LawSpec.CSharp;" ]

-- | Each unit's adapter: a stub for every declaration it must implement.
emitAdapters :: Lang -> D.Layout -> Int -> Calls -> [C.DataDeclaration] -> [C.Unit] -> Either String [Artifact]
emitAdapters lang layout bits calls declarations units = do
  names <- dataNames declarations
  forM [u | u <- orderedUnits units, not (null (unbound u)) || not (null (productionAbilities u))] $ \u -> do
    stubs <- Abilities.productionStubs lang bits declarations u
    functions <- fmap (++ stubs) $ forM (unbound u) $ \d -> do
      (ps, r) <- nativeSignature lang bits names units d
      handlerNames <- forM (Effects.uses d) $ \ref -> maybe (Left ("unknown .NET ability " ++ C.abilityKey ref)) (Right . camel . N.interfaceName) (N.abilityOf units ref)
      let name = functionName lang d
          parameters = zip (handlerNames ++ [parameterName lang i | i <- [0 ..]]) ps
          message = "not implemented: " ++ C.idText (C.declarationId d)
      pure $ case lang of
        FSharp -> D.text ("/// " ++ showType (C.declarationType d)) <> D.hardline <>
          L.linesDoc 0 (L.function 0 ("let " ++ name) (if null parameters then ["()"] else ["(" ++ p ++ ": " ++ t ++ ")" | (p, t) <- parameters]) (Just r)
            (L.App "failwith" [L.A (stringLiteral FSharp message)]))
        CSharp -> D.text ("/// <summary>" ++ showType (C.declarationType d) ++ "</summary>") <> D.hardline <>
          D.text ("public static " ++ r ++ " " ++ name ++ "(" ++ intercalate ", " [t ++ " " ++ p | (p, t) <- parameters] ++ ")") <>
          D.hardline <> D.block 4 (D.text ("throw new NotImplementedException(" ++ stringLiteral CSharp message ++ ");"))
    let header = case lang of
          FSharp -> D.text "// User-owned LawSpec adapter. Implement these functions." <> D.hardline <>
            D.text ("module " ++ unitQualified (C.unitId u)) <> D.hardline <> D.hardline <>
            D.joinWith (D.hardline <> D.hardline) functions <> D.hardline
          CSharp -> D.text "// User-owned LawSpec adapter. Implement these methods." <> D.hardline <>
            D.text ("namespace " ++ unitNamespace (C.unitId u) ++ ";") <> D.hardline <> D.hardline <>
            D.joinWith D.hardline (map D.text adapterUsingLines) <> D.hardline <> D.hardline <>
            D.text ("public static class " ++ unitModule (C.unitId u)) <> D.hardline <>
            D.block 4 (D.joinWith (D.hardline <> D.hardline) functions) <> D.hardline
        path = adapterPath lang (C.unitId u)
    pure (AdapterArtifact path (D.render layout header) "user" "source" (D.render (D.Pretty 100) header))
  where
    unbound u = [d | d <- adapterDeclarations u, lookup (C.declarationId d) calls == Nothing]
    productionAbilities u = [a | a <- N.ownAbilities u, not (C.isFail (C.abilityInstance a)), C.abilityNative a == Nothing, not (Effects.hasDefault a)]
    showType t = case t of
      C.Arrow a b -> "(" ++ showType a ++ " -> " ++ showType b ++ ")"
      C.Constructor n [] -> n
      C.Constructor n args -> n ++ concat [" (" ++ arg a ++ ")" | a <- args]
      C.TypeVariable v -> C.idText v
    arg (C.TypeArgument t) = showType t
    arg (C.IndexArgument _) = "_"
