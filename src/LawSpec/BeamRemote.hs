-- | Content hashes select checked definitions on the server. Native callers
-- get a typed function per definition; only the server supplies its abilities.
-- ref:DEC-distribution-canonical-wire ref:DEC-native-bindings-typed-identity
module LawSpec.BeamRemote (emit, available) where

import qualified LawSpec.Core as C
import qualified LawSpec.Code.Doc as D
import qualified LawSpec.BeamCode as E
import qualified LawSpec.ElixirCode as X
import qualified LawSpec.GleamCode as G
import qualified LawSpec.BeamDefinitions as Definitions
import qualified LawSpec.BeamEffects as Effects
import qualified LawSpec.BeamAbilities as Abilities
import qualified LawSpec.Remote as R
import LawSpec.Common (Artifact(..))
import LawSpec.Testing (Plan(..), PlannedUnit(..))
import Control.Monad (forM, unless)
import Data.List (nub)

data NativeType = NativeType D.Doc D.Doc D.Doc [D.Doc]
data Function = Function String [(String, NativeType)] NativeType [D.Doc]

available :: Plan -> Bool
available = not . null . snd . R.remoteManifest

emit :: String -> D.Layout -> Plan -> Either String [Artifact]
emit _ _ plan | not (available plan) = pure []
emit target layout plan = do
  names <- E.dataNames declarations
  let native ty = NativeType <$> E.nativeType bits names [] ty <*> X.nativeType bits names [] ty <*>
        G.nativeType False names [] ty <*> pure (G.imports False [ty])
      entries = Definitions.entries units
      declared = [(C.declarationId d,(u,d)) | u <- units, def <- C.unitDefinitions u, let d = C.definitionDeclaration def]
      resolve r = maybe (Left "remote definition has no checked declaration") Right (lookup (R.remoteId r) declared)
      wire r = E.record [(E.atom "arguments",E.array (map descriptor (R.remoteArguments r))),
        (E.atom "result",descriptor (R.remoteResult r))]
      signatureTable = E.record [(E.binary (R.remoteDigest r),wire r) | r <- remotes]
      digestTable = E.record [(E.binary (R.remoteName r),E.binary (R.remoteDigest r)) | r <- remotes]
      bridge direction ty value = do
        ref <- E.typeReference ty
        pure (E.remote "lawspec_beam_schema" direction [value,ref,schema])
  resolved <- mapM (\r -> (,) r <$> resolve r) remotes
  parameters <- forM (zip [0::Int ..] (nub (concatMap (Effects.uses . snd . snd) resolved))) $ \(i,a) -> do
    ty <- NativeType <$> Abilities.nativeType "erlang" units a <*> Abilities.nativeType "elixir" units a <*>
      Abilities.nativeType "gleam" units a <*> Abilities.gleamImports units [a]
    pure (a,("handler" ++ show i,ty))
  served <- forM resolved $ \(r,(_,d)) -> do
    let (argumentTypes,resultType) = C.functionType (C.declarationType d)
        arguments = [variable ("argument" ++ show i) | (i,_) <- zip [0::Int ..] argumentTypes]
        supplied = [(a,variable p) | (a,(p,_)) <- parameters, a `elem` Effects.uses d]
    checks <- sequence [bridge "validate" ty value | (ty,value) <- zip argumentTypes arguments]
    name <- maybe (Left "remote definition has no checked implementation") Right (lookup (R.remoteId r) entries)
    result <- bridge "validate" resultType (E.remote "lawspec_definitions" name (schema:symbols:arguments))
    body <- if null supplied then pure (E.sequenceDoc (fresh ++ checks ++ [result]))
      else Abilities.publicBody units supplied (E.sequenceDoc (checks ++ [result]))
    pure (E.binary (R.remoteDigest r), E.remote "maps" "put" [E.atom "invoke",E.lambda [E.array arguments] body,wire r])
  text <- native (C.Constructor "Text" [])
  milliseconds <- native (C.Constructor "Integer" [])
  let rootFunctions =
        [Function "serve" (("node",nodeType):map snd parameters) text
          [E.remote "lawspec_beam_remote" "serve" [variable "node",E.binary "definitions",E.binary "eval",E.record served]],
         Function "digest" [("name",text)] text [E.remote "maps" "get" [variable "name",digestTable]]]
      -- The Erlang core entry deals in logical values; native facades below
      -- expose ordinary typed arguments and results instead.
      evaluate = E.function "evaluate" (map variable ["node","address","name","arguments","timeout_milliseconds"])
        [D.text "_LsConnection = " <> E.remote "lawspec_beam_remote" "connect"
          [variable "node",D.text "<<_LsAddress/binary, \"/definitions\">>",E.binary "eval",signatureTable,variable "timeout_milliseconds"],
         E.remote "lawspec_beam_remote" "call" [D.text "_LsConnection",E.call "digest" [variable "name"],variable "arguments"]]
  root <- render target layout "lawspec_remote" "lawspec/remote" "LawSpec.Remote" rootFunctions [("evaluate",5)] [evaluate]
  clients <- concat <$> forM units (\unit -> do
    let mine = [(r,d) | (r,(u,d)) <- resolved, C.unitId u == C.unitId unit]
    if null mine then pure [] else do
      functions <- concat <$> forM mine (\(r,d) -> do
        let (argumentTypes,resultType) = C.functionType (C.declarationType d)
            name = E.nativeName target (E.snake (C.declarationName d))
        arguments <- sequence [(,) ("argument" ++ show i) <$> native ty | (i,ty) <- zip [0::Int ..] argumentTypes]
        resultTy <- native resultType
        logical <- sequence [bridge "from_native" ty (variable p) | (ty,(p,_)) <- zip argumentTypes arguments]
        result <- bridge "to_native" resultType (E.remote "lawspec_remote" "evaluate"
          [variable "node",variable "address",E.binary (R.remoteName r),E.array logical,variable "timeout_milliseconds"])
        let basic = [("node",nodeType),("address",text)] ++ arguments
            explicit = [("node",nodeType),("address",text),("timeout_milliseconds",milliseconds)] ++ arguments
        pure [Function name basic resultTy
                [E.call (name ++ "_with_timeout") (map variable ["node","address"] ++ [D.text "5000"] ++ map (variable . fst) arguments)],
              Function (name ++ "_with_timeout") explicit resultTy (fresh ++ [result])])
      render target layout ("lawspec_remote_" ++ E.moduleName (C.unitId unit))
        ("lawspec/remote/" ++ E.gleamPath (C.unitId unit))
        ("LawSpec.Remote." ++ drop 7 (E.nativeModule "elixir" unit)) functions [] [])
  let artifacts = root ++ clients
  unless (length (map artifactPath artifacts) == length (nub (map artifactPath artifacts)))
    (Left "BEAM remote modules collide after native name conversion")
  pure artifacts
  where
    units = map plannedUnit (plannedUnits plan)
    declarations = planDataDeclarations plan
    bits = planMachineBits plan
    (forms,remotes) = R.remoteManifest plan
    descriptor d = E.binary (unwords (forms ++ [d]))

schema, symbols :: D.Doc
schema = D.text "_LsSchema"
symbols = D.text "_LsSymbols"
variable :: String -> D.Doc
variable = D.text . ("_Ls" ++) . E.pascal
fresh :: [D.Doc]
fresh = [symbols <> D.text " = make_ref()",schema <> D.text " = " <> E.remote "lawspec_data" "schema" [symbols]]
nodeType :: NativeType
nodeType = NativeType (E.remote "lawspec_network" "node_handle" []) (X.remote "LawSpec.Network" "node_handle" []) (D.text "network.Node") [D.text "import lawspec/network"]

render :: String -> D.Layout -> String -> String -> String -> [Function] -> [(String,Int)] -> [D.Doc] -> Either String [Artifact]
render target layout name path elixirName functions extraExports extraBodies = do
  let raw = [n | Function n _ _ _ <- functions]
  unless (length raw == length (nub raw) && all ((<= 255) . length) raw && length name <= 230 &&
    all (\(Function _ ps _ _) -> length ps <= 255) functions)
    (Left "BEAM remote method names collide or exceed native limits")
  pure (Artifact ("src/" ++ name ++ ".erl") (D.render layout erlang) "generated" "source" : case target of
    "elixir" -> [Artifact ("lib/" ++ path ++ ".ex") (D.render layout elixir) "generated" "source"]
    "gleam" -> [Artifact ("src/" ++ path ++ ".gleam") (D.render layout gleam) "generated" "source"]
    _ -> [])
  where
    erlType (NativeType e _ _ _) = e
    exType (NativeType _ x _ _) = x
    gleamType (NativeType _ _ g _) = g
    imports (NativeType _ _ _ i) = i
    erlang = E.moduleDoc name ([(n,length ps) | Function n ps _ _ <- functions] ++ extraExports)
      (concat [[D.text "-spec " <> E.call n (map (erlType . snd) ps) <> D.text " -> " <> erlType result <> D.text ".",
        E.function n (map (variable . fst) ps) body] | Function n ps result body <- functions] ++ extraBodies)
    elixir = X.moduleDoc elixirName False (concat
      [[D.text "@spec " <> X.call n (map (exType . snd) ps) <> D.text " :: " <> exType result,
        X.function n (map (D.text . fst) ps) [X.remote (":" ++ name) n (map (D.text . fst) ps)]]
        | Function n ps result _ <- functions])
    gleam = G.fileDoc False
      (nub (concat [concatMap (imports . snd) ps ++ imports result | Function _ ps result _ <- functions]) ++
       [G.external name n n [D.text (p ++ ": ") <> gleamType ty | (p,ty) <- ps] (gleamType result)
        | Function n ps result _ <- functions])
