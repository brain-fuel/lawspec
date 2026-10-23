-- | Abilities as Swift protocols. Each ability instance is a protocol with a
-- method per operation (Gateway.authorize); a native handler conforms to it,
-- and a bridge turns a native handler into a logical one and back,
-- converting values and failures. An operation that fails with E throws E.
-- Spec handlers are made by their unit's generated enum from its clause
-- definitions. ref:DEC-typed-core-boundary ref:DEC-idiomatic-generated-types
-- ref:DEC-swift-runtime-from-scratch
module LawSpec.Swift.Abilities
  ( emitProtocols, emitBridges, unitFactories, productionStubs, failureOf, emitDefaults, operationSignature
  , failingKey
  ) where

import qualified LawSpec.Core as C
import qualified LawSpec.Code.Doc as D
import qualified LawSpec.AbilityNames as N
import LawSpec.Common (Artifact(..))
import LawSpec.Swift.Code
import LawSpec.SourceLink (generatedHeader, unitSourceFile)
import LawSpec.Swift.Names
import LawSpec.Swift.Entries
import qualified LawSpec.Swift.Data as Data
import qualified LawSpec.Swift.Effects as Effects
import qualified LawSpec.Swift.Expr as X
import Control.Monad (forM)
import Data.List (intercalate)

-- | The failure an operation fails with, if any.
failureOf :: C.Ability -> String -> Maybe C.Type
failureOf a op = case lookup op (C.abilityFailures a) of
  Just (C.AbilityRef _ [failure]) -> Just failure
  _ -> Nothing

-- | The key of the Fail ability an operation fails through.
failingKey :: C.Ability -> String -> String
failingKey a op = case lookup op (C.abilityFailures a) of
  Just failing -> C.abilityKey failing
  Nothing -> ""

isUnit :: C.Type -> Bool
isUnit t = t == C.Constructor "Unit" []

-- | An operation's native parameters (without Unit), result (Void for
-- Unit) and failure.
operationSignature :: Int -> Data.Names -> C.Ability -> (String, C.Type) -> Either String ([(String, String)], String, Maybe String)
operationSignature bits names a (op, ty) = do
  let (args, result) = C.functionType ty
  ps <- mapM (Data.nativeType bits names []) [t | t <- args, not (isUnit t)]
  r <- if isUnit result then pure "Void" else Data.nativeType bits names [] result
  e <- traverse (Data.nativeType bits names []) (failureOf a op)
  pure (zip ["value" ++ show i | i <- [0 :: Int ..]] ps, r, e)

-- | An operation's method: its requirement in a protocol, or with a body.
method :: String -> ([(String, String)], String, Maybe String) -> Maybe D.Doc -> D.Doc
method op (ps, r, e) body = case body of
  Nothing -> D.text opening <> argumentsDoc (map D.text parameters) <> D.text closing
  Just b -> signature opening parameters closing b
  where
    opening = "func " ++ Effects.operationMember op
    parameters = ["_ " ++ p ++ ": " ++ t | (p, t) <- ps]
    closing = maybe "" (\x -> " throws(" ++ x ++ ")") e ++ (if r == "Void" then "" else " -> " ++ r)

-- | One file of protocols, an enum for each unit's abilities.
emitProtocols :: D.Layout -> Int -> [C.DataDeclaration] -> [C.Unit] -> Either String [Artifact]
emitProtocols layout bits declarations units
  | null (Effects.abilities units) = pure []
  | otherwise = do
      names <- dataNames declarations
      groups <- forM [u | u <- units, not (null (own u))] $ \u -> do
        protocols <- forM (own u) $ \a -> do
          members <- forM (C.abilityOperations a) $ \(op, ty) -> do
            signature <- operationSignature bits names a (op, ty)
            pure (D.text ("/// " ++ op) <> D.hardline <> method op signature Nothing)
          pure (D.text ("/// The native protocol of " ++ N.displayName a ++ " (" ++ C.abilityKey (C.abilityInstance a) ++ ").") <> D.hardline <>
            D.text ("public protocol " ++ pascal (N.interfaceName a) ++ " {") <> D.nest 2 (D.hardline <> D.joinWith D.hardline members) <>
            D.hardline <> D.text "}")
        let enumName = last (splitDots (Effects.abilityNamespace (C.unitId u)))
        pure (D.text ("/// The native protocols of " ++ C.idText (C.unitId u) ++ "'s abilities.") <> D.hardline <>
          D.text ("public enum " ++ enumName ++ " {") <> D.nest 2 (D.hardline <> D.joinWith (D.hardline <> D.hardline) protocols) <>
          D.hardline <> D.text "}")
      let doc = fileHeader (generatedHeader Nothing) [["import LawSpecRuntime"]] <> D.hardline <>

            D.text "extension LawSpec.Abilities {" <> D.nest 2 (D.hardline <> D.joinWith (D.hardline <> D.hardline) groups) <> D.hardline <>
            D.text "}" <> D.hardline
      pure [Artifact "src/LawSpec/LawSpecAbilities.swift" (D.render layout doc) "generated" "source"]
  where
    own u = [a | a <- N.ownAbilities u, not (C.isFail (C.abilityInstance a))]

-- | The bridges between native protocols and logical handlers.
emitBridges :: D.Layout -> Int -> [C.DataDeclaration] -> [C.Unit] -> Either String [Artifact]
emitBridges layout bits declarations units
  | null (Effects.abilities units) = pure []
  | otherwise = do
      names <- dataNames declarations
      bodies <- mapM (bridge names) (Effects.abilities units)
      let doc = fileHeader (generatedHeader Nothing) [["import LawSpecRuntime"]] <> D.hardline <>

            D.text "extension LawSpec {" <> D.nest 2 (D.hardline <>
              D.text "/// Bridges between each ability's native protocol and its logical handlers." <> D.hardline <>
              D.text "public enum AbilityBridges {" <> D.nest 2 (D.hardline <> D.joinWith (D.hardline <> D.hardline) bodies) <>
              D.hardline <> D.text "}") <> D.hardline <>
            D.text "}" <> D.hardline
      pure [Artifact "src/LawSpec/LawSpecAbilityBridges.swift" (D.render layout doc) "generated" "source"]
  where
    bridge names a = do
      let key = C.abilityKey (C.abilityInstance a)
          proto = Effects.protocolType a
          className = pascal (Effects.bridgeName a "Bridge")
      members <- forM (C.abilityOperations a) $ \(op, ty) -> do
        let (args, result) = C.functionType ty
        signature@(ps, r, failure) <- operationSignature bits names a (op, ty)
        codecs <- mapM (Data.codec bits names []) args
        out <- Data.codec bits names [] result
        let values = go codecs args (map fst ps)
              where go (c : cs) (t : ts) ns
                      | isUnit t = Raw "Value.unit" : go cs ts ns
                      | (n : rest) <- ns = Call (c ++ ".fromNative") [Var n] : go cs ts rest
                    go _ _ _ = []
            logical = Call "Effects.invoke" [Raw "self.originHandler", Raw "self.originSchema", Str op, ListOf tValues values]
            void = r == "Void"
            closure = Lambda [] (Ty r) (if void then logical else Call (out ++ ".toNative") [logical])
        runner <- case failure of
          Nothing -> pure (Pure "Embedding.run" [closure])
          Just _ -> do
            fc <- maybe (Left "missing failure") (Data.codec bits names []) (failureOf a op)
            pure (Call "Embedding.runFailing" [Str (failingKey a op), Raw ("{ try " ++ fc ++ ".toNative($0) }"), closure])
        pure (method op signature (Just (if void then renderStatements (Statement runner) else renderBody (Ty r) runner)))
      clauses <- forM (C.abilityOperations a) $ \(op, ty) -> do
        let (args, result) = C.functionType ty
        (_, r, failure) <- operationSignature bits names a (op, ty)
        codecs <- mapM (Data.codec bits names []) args
        out <- Data.codec bits names [] result
        ref <- X.typeRef result
        let nativeArgs = [(i, c) | (i, c, t) <- zip3 [0 :: Int ..] codecs args, not (isUnit t)]
            argumentName i = "argument" ++ show i
            callNative = Pure ("box.value." ++ Effects.operationMember op) [Var (argumentName i) | (i, _) <- nativeArgs]
        invoked <- case (failure, failureOf a op) of
          (Just e, Just ft) -> do
            fc <- Data.codec bits names [] ft
            pure (Call "Effects.ofThrown" [Str (failingKey a op),
              Raw ("{ (failure: " ++ e ++ ") throws -> Value in try " ++ fc ++ ".fromNative(failure) }"),
              Raw ("{ () throws(" ++ e ++ ") -> " ++ r ++ " in try " ++ D.render D.Compact (renderExpr callNative) ++ " }")])
          _ -> pure callNative
        let result = if r == "Void"
              then Do [Statement invoked] (Raw "Value.unit")
              else call "Schema" "validate" [Call (out ++ ".fromNative") [invoked], ref, Var "current"]
            body = foldr (\(i, c) rest -> Let (argumentName i) (Ty "") (Call (c ++ ".toNative") [Raw ("arguments[" ++ show i ++ "]")]) rest)
              result nativeArgs
        pure (TupleOf [Str op, Lambda [("current", tSchema), ("arguments", tValues)] tValue body])
      let classDoc = typeDeclaration ("final class " ++ className) [proto, "Effects.Origin", "@unchecked Sendable"] (
            D.joinWith D.hardline (map D.text
              [ "let originSchema: Schema", "let originSymbols: SymbolContext", "let originHandler: Effects.Handler"
              , "var originAbility: String { " ++ stringLiteral key ++ " }", "" ]) <> D.hardline <>
            D.text "init(_ schema: Schema, _ symbols: SymbolContext, _ handler: Effects.Handler) {" <> D.nest 2 (D.hardline <>
              D.joinWith D.hardline (map D.text ["originSchema = schema", "originSymbols = symbols", "originHandler = handler"])) <> D.hardline <>
            D.text "}" <> D.hardline <> D.hardline <>
            D.joinWith (D.hardline <> D.hardline) members)
          toNative = D.text ("/// " ++ N.displayName a ++ "'s native protocol over a logical handler.") <> D.hardline <>
            signature ("public static func " ++ Effects.bridgeName a "ToNative") ["_ schema: Schema", "_ symbols: SymbolContext", "_ handler: Effects.Handler"]
              (" throws -> any " ++ proto) (D.text (className ++ "(schema, symbols, handler)"))
          fromNative = D.text ("/// The logical handler of a native " ++ N.displayName a ++ ".") <> D.hardline <>
            signature ("public static func " ++ Effects.bridgeName a "FromNative") ["_ schema: Schema", "_ symbols: SymbolContext", "_ native: any " ++ proto]
              " throws -> Effects.Handler" (D.text "let box = UncheckedBox(native)" <> D.hardline <>
              D.text ("return Effects.recover(native, " ++ stringLiteral key ++ ", symbols) {") <> D.nest 2 (D.hardline <>
                renderExpr (Pure "Effects.stateless" [ListOf (Ty "[(String, Effects.Clause)]") clauses])) <>
              D.hardline <> D.text "}")
          recording = D.text ("/// A recording of a native " ++ N.displayName a ++ ".") <> D.hardline <>
            signature ("public static func " ++ Effects.bridgeName a "Recording") ["_ schema: Schema", "_ symbols: SymbolContext", "_ native: any " ++ proto]
              (" throws -> any " ++ proto) (renderBody (Ty "") (Call (Effects.bridgeName a "ToNative") [Var "schema", Var "symbols",
                Pure "Effects.recording" [Call (Effects.bridgeName a "FromNative") [Var "schema", Var "symbols", Var "native"]]]))
      pure (D.joinWith (D.hardline <> D.hardline) [classDoc, toNative, fromNative, recording])

-- | A unit's handler factories, in its generated enum: its abilities'
-- production handlers (from its adapter) and its spec handlers.
unitFactories :: Int -> [C.DataDeclaration] -> [C.Unit] -> C.Unit -> Either String [D.Doc]
unitFactories bits declarations units unit = do
  names <- dataNames declarations
  productions <- forM [a | a <- N.ownAbilities unit, not (C.isFail (C.abilityInstance a)), not (Effects.hasDefault a) || C.abilityNative a /= Nothing] $ \a -> do
    resourceCodec <- traverse (Data.codec bits names []) (C.abilityResource a)
    let (_, name) = Effects.productionFunction a
        made = case C.abilityNative a of
          Just ref -> Pure (intercalate "." ref) []
          Nothing -> Pure (unitQualified (C.unitId unit) ++ "." ++ camel (N.productionName a)) [Call (c ++ ".toNative") [Var "resource"] | Just c <- [resourceCodec]]
        params = ["_ schema: Schema", "_ symbols: SymbolContext"] ++ ["_ resource: Value" | Just _ <- [resourceCodec]]
    pure (D.text ("/// The production handler of " ++ N.displayName a ++ ", from the adapter.") <> D.hardline <>
      signature ("public static func " ++ name) params " throws -> Effects.Handler"
        (renderBody Effects.handlerTy (call "LawSpec.AbilityBridges" (Effects.bridgeName a "FromNative") [Var "schema", Var "symbols", made])))
  specs <- forM (C.unitHandlers unit) $ \h -> do
    answered <- forM (C.handlerAbilities h) $ \ref -> maybe (Left "unknown Swift spec handler ability") Right (N.abilityOf units ref)
    let stateful = C.handlerState h /= Nothing
    clauses <- forM (concatMap C.abilityOperations answered) $ \(op, ty) -> do
      identity <- maybe (Left ("missing Swift spec handler clause " ++ op)) Right (lookup op (C.handlerClauses h))
      e <- maybe (Left "missing Swift spec clause definition") Right (lookup identity (entries units))
      let arity = length (fst (C.functionType ty))
          args = [pure' "Runtime" "item" [IntLit (toInteger i), Var "arguments"] | i <- [0 .. arity - 1]]
          parameters = if stateful then Var "state" : args else if null args then [Raw "Value.unit"] else args
          body = entryCall e (Var "current" : Var "symbols" : parameters)
          params = [("current", tSchema), ("arguments", tValues)] ++ [("state", tValue) | stateful]
      pure (TupleOf [Str op, Lambda params tValue body])
    start <- case C.handlerState h of
      Nothing -> pure Nothing
      Just (_, initial) -> Just <$> X.render (X.Context bits X.schemaVar X.symbolsVar
        (\i -> error ("unbound Swift handler state: " ++ C.idText i)) (Effects.external units) X.typeRef X.typeKeyOf) initial
    let clauseTy = if stateful then Ty "[(String, Effects.StatefulClause)]" else Ty "[(String, Effects.Clause)]"
        made = case start of
          Nothing -> pure' "Effects" "stateless" [ListOf clauseTy clauses]
          Just v -> pure' "Effects" "stateful" [v, ListOf clauseTy clauses]
        (_, name) = Effects.specFunction units h
    pure (D.text ("/// The spec handler " ++ C.handlerName h ++ ".") <> D.hardline <>
      signature ("public static func " ++ name) ["_ schema: Schema", "_ symbols: SymbolContext"] " throws -> Effects.Handler"
        (renderBody Effects.handlerTy made))
  pure (productions ++ specs)

-- | The native handlers a unit's adapter implements.
productionStubs :: Int -> [C.DataDeclaration] -> C.Unit -> Either String [D.Doc]
productionStubs bits declarations unit = do
  names <- dataNames declarations
  fmap concat $ forM [a | a <- N.ownAbilities unit, not (C.isFail (C.abilityInstance a)), C.abilityNative a == Nothing, not (Effects.hasDefault a)] $ \a -> do
    members <- forM (C.abilityOperations a) $ \(op, ty) -> do
      signature <- operationSignature bits names a (op, ty)
      let message = "not implemented: " ++ C.abilityKey (C.abilityInstance a) ++ "." ++ op
      pure (method op signature (Just (callDoc "fatalError" [D.text (stringLiteral message)])))
    resource <- traverse (Data.nativeType bits names []) (C.abilityResource a)
    let proto = Effects.protocolType a
        cls = "Native" ++ pascal (N.interfaceName a)
        name = camel (N.productionName a)
    pure [ D.text ("/// The native handler of " ++ N.displayName a ++ ": " ++ intercalate ", " (map fst (C.abilityOperations a)) ++ ".") <> D.hardline <>
           signature ("static func " ++ name) ["_ resource: " ++ t | Just t <- [resource]] (" -> any " ++ proto) (D.text (cls ++ "()"))
         , D.text ("struct " ++ cls ++ ": " ++ proto ++ " {") <> D.nest 2 (D.hardline <> D.joinWith (D.hardline <> D.hardline) members) <>
           D.hardline <> D.text "}" ]

-- | The default handlers of the built-in abilities, as their native
-- protocols: what a bound handler wraps, and what applications use.
emitDefaults :: D.Layout -> [C.Unit] -> Either String [Artifact]
emitDefaults layout units
  | null defaults = pure []
  | otherwise = do
      let functions =
            [ D.text ("/// The default handler of " ++ N.displayName a ++ ".") <> D.hardline <>
              signature ("public static func " ++ escape (camel (N.interfaceName a))) [] (" -> any " ++ Effects.protocolType a)
                (renderBody (Ty "") (Pure "Embedding.run" [Lambda [] (Ty (Effects.protocolType a)) (call "LawSpec.AbilityBridges" (Effects.bridgeName a "ToNative")
                  [Raw "LawSpec.Program.schema", Raw "SymbolContext()", call "Defaults" "handler" [Str (C.abilityKey (C.abilityInstance a))]])]))
            | a <- defaults ] ++
            [ D.text "/// The SLH-DSA (FIPS 205) signature handler." <> D.hardline <>
              signature "public static func slhDsaSignature" [] (" -> any " ++ Effects.protocolType a)
                (renderBody (Ty "") (Pure "Embedding.run" [Lambda [] (Ty (Effects.protocolType a)) (call "LawSpec.AbilityBridges" (Effects.bridgeName a "ToNative")
                  [Raw "LawSpec.Program.schema", Raw "SymbolContext()", Pure "Crypto.slhDsaSignatureHandler" []])]))
            | a <- defaults, C.abilityKey (C.abilityInstance a) == "lawspec.crypto::ability::Signature" ]
          doc = fileHeader (generatedHeader Nothing) [["import LawSpecRuntime"]] <> D.hardline <>

            D.text "extension LawSpec {" <> D.nest 2 (D.hardline <>
              D.text "/// The runtime's default handlers of the built-in abilities, as native protocols." <> D.hardline <>
              D.text "public enum DefaultHandlers {" <> D.nest 2 (D.hardline <> D.joinWith (D.hardline <> D.hardline) functions) <>
              D.hardline <> D.text "}") <> D.hardline <>
            D.text "}" <> D.hardline
      pure [Artifact "src/LawSpec/LawSpecDefaultHandlers.swift" (D.render layout doc) "generated" "source"]
  where defaults = [a | a <- Effects.abilities units, Effects.hasDefault a]
