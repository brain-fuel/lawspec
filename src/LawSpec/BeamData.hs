-- | BEAM schema metadata and native Erlang data declarations come from the
-- same checked Core registry, including field contracts and GADT witnesses.
-- ref:DEC-idiomatic-generated-types ref:DEC-native-bindings-typed-identity
module LawSpec.BeamData (emitData) where

import qualified LawSpec.Core as C
import qualified LawSpec.Core.Schema as S
import qualified LawSpec.Code.Doc as D
import qualified LawSpec.BeamCode as E
import qualified LawSpec.BeamExpr as Expr
import qualified LawSpec.BeamGenerators as Generators
import LawSpec.Testing (GeneratorRequirement(..), domainHints)
import LawSpec.Core.Types (makeRegistry, freeExistentials)
import LawSpec.Core.Total (constructorProofContracts)
import LawSpec.Scalar (primitives, primitiveName)
import LawSpec.Common (Artifact(..))
import Control.Monad (forM, unless)
import Data.List (nub)

emitData :: String -> D.Layout -> Int -> [C.DataDeclaration] -> Either String Artifact
emitData target layout bits declarations = do
  _ <- makeRegistry declarations
  _ <- either (Left . show) Right (constructorProofContracts bits declarations)
  names <- E.dataNames declarations
  (schemas,contracts) <- S.dataSchemasWithContracts declarations
  definitions <- if target == "erlang" then mapM (nativeDefinition names) declarations else pure []
  metadata <- forM schemas $ \definition -> do
    cs <- forM (S.constructors definition) $ \c -> do
      tag <- named names (C.Id (S.constructorTag c))
      predicates <- sequence [predicate contract expression | contract <- contracts,
        S.contractTag contract == S.constructorTag c, expression <- S.contractPredicates contract]
      generators <- fmap concat $ mapM fieldGenerators
        [contract | contract <- contracts, S.contractTag contract == S.constructorTag c]
      native <- nativeShape tag (S.constructorTag c)
      pure (E.record ([(E.atom "tag",E.binary (S.constructorTag c)),
        (E.atom "fields",E.array [E.tuple [E.binary (S.fieldName f),E.reference (S.fieldType f)] | f <- S.fields c])] ++ native ++
        [(E.atom "predicates",E.array predicates) | not (null predicates)] ++
        [(E.atom "generators",E.record generators) | not (null generators)] ++
        [(E.atom "indices",E.array (map E.binary (S.constructorIndex c))) | not (null (S.constructorIndex c))] ++
        [(E.atom "refinements",E.array [E.tuple [D.text (show i),E.reference t] | (i,t) <- S.constructorRefinements c]) | not (null (S.constructorRefinements c))] ++
        [(E.atom "existentials",D.text (show (S.constructorExistentials c))) | S.constructorExistentials c > 0] ++
        [(E.atom "witnesses",E.array (map (D.text . show) (S.constructorWitnesses c))) | not (null (S.constructorWitnesses c))]))
    pure (E.record ([(E.atom "name",E.binary (S.typeName definition)),
      (E.atom "parameters",D.text (show (S.parameterCount definition))),
      (E.atom "constructors",E.array cs)] ++
      [(E.atom "handle",E.atom "true") | any (\d -> C.idText (C.dataId d) == S.typeName definition && C.dataHandle d) declarations]))
  exports <- mapM (\d -> do
    name <- named names (C.dataId d)
    pure (E.atom name <> D.text ("/" ++ show (length (C.dataParameters d))))) [d | d <- declarations, target == "erlang"]
  let schema = E.remote "lawspec_beam_schema" "new" [E.array metadata,
        E.array (map (E.binary . primitiveName) primitives),D.text (show bits)]
      factory = E.function "schema" [D.text "_LsSymbols"]
        [if target == "gleam" then E.remote "lawspec_beam_schema" "with_codecs"
          [schema,E.remote "lawspec_beam_gleam" "codecs" []] else schema]
      body = [D.text "-export_type(" <> E.array exports <> D.text ")." | not (null exports)] ++ definitions ++ [factory]
  pure (Artifact "src/lawspec_data.erl" (D.render layout (E.moduleDoc "lawspec_data" [("schema",1)] body)) "generated" "source")
  where
    nativeShape tag identity
      | target == "gleam" = pure [(E.atom "native_tag",E.atom (E.snake (E.pascal tag)))]
      | target /= "elixir" = pure [(E.atom "native_tag",E.atom tag)]
      | otherwise = case [(d,c) | d <- declarations, c <- C.dataConstructors d, C.idText (C.constructorId c) == identity] of
          [(d,c)] -> do
            let fields = E.elixirFields d c
                variables = [D.text ("_LsField" ++ show i) | (i,_) <- zip [0::Int ..] fields]
                entries = (E.atom "__struct__", E.atom ("Elixir." ++ E.elixirDataModule tag)) : zip (map E.atom fields) variables
                patternDoc = D.delimit 4 "#{" "}" [a <> D.text " := " <> b | (a,b) <- entries]
            unless (all (\n -> not (null n) && length n <= 255 && n /= "__struct__") fields && length fields == length (nub fields))
              (Left "Elixir struct fields collide after snake_case conversion or exceed the atom limit")
            pure [(E.atom "encode",E.lambda [E.array variables] (E.record entries)),
              (E.atom "decode",D.group (D.text "fun(" <> patternDoc <> D.text ") -> " <>
                E.tuple [E.atom "ok",E.array variables] <> D.text "; (_) -> no_match end"))]
          _ -> Left "missing Elixir constructor metadata"
    named names identity = maybe (Left ("unresolved BEAM data name: " ++ C.idText identity)) Right (lookup identity names)
    nativeDefinition names d = do
      name <- named names (C.dataId d)
      let parameters = zip (C.dataParameters d) ["_T" ++ show i | i <- [0::Int ..]]
      cases <- forM (C.dataConstructors d) $ \c -> do
        tag <- named names (C.constructorId c)
        let scope = parameters ++ [(i,"term()") | i <- C.constructorExistentials c]
        fields <- mapM (E.nativeType bits names scope . C.binderType) (C.constructorFields c)
        let witnesses = [E.call "binary" [] | _ <- freeExistentials d c]
        pure (if null fields && null witnesses then E.atom tag else E.tuple (E.atom tag : fields ++ witnesses))
      let variants = if C.dataHandle d then map (\n -> E.call n []) ["pid","reference","port"] ++
              [E.tuple [E.atom "lawspec_actor",E.call "pid" [],E.array [E.call "term" []]]]
            else if null cases then [E.call "none" []] else cases
      pure (D.group (D.text "-type " <> E.call name (map (D.text . snd) parameters) <>
        D.text " ::" <> D.nest 4 (D.softline <> D.joinWith (D.softline <> D.text "| ") variants) <> D.text "."))
    -- Safe constructor-field bounds may depend on fields already drawn.
    -- The full predicate remains authoritative for every sample and shrink.
    -- ref:DEC-shrink-within-domain
    fieldGenerators contract = fmap concat $ forM (zip [0::Int ..] (S.contractFields contract)) $ \(i,binder) -> do
      let predicates = S.contractPredicates contract
          q = C.Quantifier binder predicates []
          requirement = GeneratorRequirement binder predicates [] [] (domainHints q) Nothing
          earlier = map C.binderId (take i (S.contractFields contract))
          available expression = all (`elem` earlier) (C.freeBinders expression)
          bounds = filter (available . snd) (Generators.directBounds requirement)
          lengths = filter (available . snd) (Generators.lengthBounds requirement)
          hints = [hint | hint <- domainHints q, C.expressionType hint == C.binderType binder, available hint]
      if null bounds && null lengths && null hints then pure [] else do
        body <- contractCode contract $ \render -> do
          bs <- mapM (\(op,e) -> do
            value <- render e
            pure (E.tuple [E.binary (C.binaryName op),value])) bounds
          ls <- mapM (\(op,e) -> do
            value <- render e
            pure (E.tuple [E.atom "length",E.binary (C.binaryName op),value])) lengths
          hs <- mapM render hints
          pure (E.tuple [E.array (bs ++ ls),E.array hs])
        pure [(D.text (show (i + 1)),body)]
    predicate contract expression = contractCode contract (\render -> render expression)
    contractCode contract build = do
      let local identity = maybe (error "unbound BEAM constructor field") id
            (lookup identity [(C.binderId b,"lists:nth(" ++ show i ++ ", _LsFields)") | (i,b) <- zip [1::Int ..] (S.contractFields contract)])
          ref ty = do
            raw <- E.reference <$> S.typeReference (S.contractParameters contract) ty
            pure (E.remote "lawspec_beam_schema" "substitute" [raw,D.text "_LsKnown"])
          key ty = E.remote "lawspec_beam_schema" "type_key" . pure <$> ref ty
          render = Expr.renderExpressionWithContext (D.text (show bits)) ref key
            (D.text "_LsSchema") (D.text "_LsSymbols") local
            (\_ _ _ -> Left "external call in a BEAM constructor predicate")
      body <- build render
      pure (E.lambda (map D.text ["_LsSchema","_LsTypes","_LsFields"])
        (E.sequenceDoc [D.text "_LsKnown = " <> E.remote "maps" "from_list"
          [E.remote "lists" "zip" [E.remote "lists" "seq"
            [D.text "0",D.text "length(_LsTypes) - 1"],D.text "_LsTypes"]],body]))
