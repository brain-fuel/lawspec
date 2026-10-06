-- | Kotlin expression documents over checked Core. Native calls are supplied by
-- the consumer so definitions and adapter bridges retain their own ABI.
module LawSpec.KotlinExpr (renderExpression, scalarLiteral, call, array, reference, quoted, checked, codec) where

import LawSpec.Core
import qualified LawSpec.KotlinData as Native
import qualified LawSpec.JavaData as Java
import LawSpec.Scalar
import qualified LawSpec.Code.Doc as D
import Data.Aeson (encode)
import qualified Data.Text.Lazy as T
import qualified Data.Text.Lazy.Encoding as T

-- | Strings are escaped for Kotlin here, once, so no generated literal can end
-- early or change meaning.
quoted :: String -> D.Doc
quoted value
  | length (token value) <= 26 = D.text (token value)
  | otherwise = D.group (D.text "(" <> D.nest 4
      (D.softbreak <> D.joinWith (D.text " +" <> D.softline)
        (map (D.text . token) (chunks value))) <> D.softbreak <> D.text ")")
  where
    token = concatMap escapeDollar . T.unpack . T.decodeUtf8 . encode
    escapeDollar '$' = "\\$"
    escapeDollar c = [c]
    chunks [] = []
    chunks rest =
      let count = max 1 (length (takeWhile
            (\n -> length (token (take n rest)) <= 26) [1 .. length (take 24 rest)]))
      in take count rest : chunks (drop count rest)

-- | Arguments wrap when a call is too wide, in the Kotlin style LawSpec follows.
-- ref:DEC-readable-output-default
call :: String -> [D.Doc] -> D.Doc
call name values = D.text name <> D.delimitTrailing 4 "(" ")" values

-- | Lists of runtime values are written in one shape so they wrap like calls.
array :: [D.Doc] -> D.Doc
array = call "arrayOf"

-- | Runtime checks name a type by a schema reference built from Core.
reference :: Type -> Either String D.Doc
reference = Native.kotlinTypeReferenceDoc

-- | Values of types with a schema are validated as they enter a law, so an
-- adapter cannot return a value outside its declared domain.
-- ref:DEC-portable-exact-arithmetic
checked :: [DataDeclaration] -> Int -> Type -> D.Doc -> Either String D.Doc
checked declarations bits ty value
  | Native.requiresSchema declarations ty = do
      ref <- reference ty
      pure (call "_schema.validate" [ref,value,D.text (show bits),D.text "symbols"])
  | otherwise = pure (call "LawSpecRuntime.convert"
      [quoted (Java.javaDataKey ty),value,D.text (show bits)])

-- | A codec converts between the generated Kotlin type and the runtime value,
-- checking the value as it goes.
codec :: [DataDeclaration] -> Int -> Type -> Either String D.Doc
codec declarations bits ty = do
  value <- Native.kotlinCodecDocWithContext (D.text "symbols") declarations ty
  pure (D.multiline (D.text "run " <> D.block 4 (D.joinWith D.hardline
    [D.text "val schema = _schema",D.text ("val bits = " ++ show bits),value])))

-- | Literals become runtime values built from their declared type and exact
-- digits, so Kotlin never reads a number at its own precision.
-- ref:DEC-portable-exact-arithmetic
scalarLiteral :: Type -> Scalar -> Either String D.Doc
scalarLiteral ty value = case value of
  SInteger name n -> pure (runtime "integer" [quoted name,quoted (show n)])
  SBool b -> pure (runtime "bool" [D.text (if b then "true" else "false")])
  SDecimal c e -> pure (runtime "decimal" [quoted (show c),quoted (show e)])
  SRational n d -> pure (runtime "rational" [quoted (show n),quoted (show d)])
  SFloat name pattern -> pure (runtime "floating" [quoted name,quoted pattern])
  SComplex name r i -> do
    real <- scalarLiteral (scalarType (scalarName r)) r
    imaginary <- scalarLiteral (scalarType (scalarName i)) i
    pure (runtime "complex" [quoted name,real,imaginary])
  SCharacter name c -> pure (runtime "character" [quoted name,D.text (show c)])
  SSequence name units -> pure (runtime "sequence" [quoted name,
    call "intArrayOf" (map (D.text . show) units)])
  SSymbol identity description -> pure (runtime "symbol" [quoted identity,quoted description,D.text "symbols"])
  SAbsent name -> pure (runtime "absent" [quoted name])
  SPresent name payload -> do
    let inner = case ty of Constructor _ [TypeArgument t] -> t; _ -> ty
    valueDoc <- maybe (pure (D.text "null")) (scalarLiteral inner) payload
    pure (runtime "present" [quoted (case ty of Constructor _ [_] -> Java.javaDataKey ty; _ -> name),valueDoc])
  where runtime name = call ("LawSpecRuntime." ++ name)

-- | Expressions are rendered from Core, never from source, so the Kotlin tests
-- check the same expansion as every other target.
-- ref:DEC-typed-core-boundary
renderExpression :: [DataDeclaration] -> Int -> (Id -> String)
  -> (Expr -> [D.Doc] -> Either String D.Doc) -> Expr -> Either String D.Doc
renderExpression declarations bits local external = render
  where
    width = D.text (show bits)
    key = quoted . Java.javaDataKey
    runtime name = call ("LawSpecRuntime." ++ name)
    render term
      -- An all group's steps run side by side, each on a virtual thread.
      | Just (fields,binders,body) <- concurrentGroup term = do
          steps <- mapM render fields
          inner <- render body
          let resultsName = "group" ++ show (length (show term))
              bindings = [D.text ("val " ++ local (binderId binder) ++ " = " ++ resultsName ++ "[" ++ show i ++ "]")
                | (i,binder) <- zip [0::Int ..] binders]
          pure (runtime "concurrently" ((D.text ("{ " ++ resultsName ++ " ->") <>
            D.nest 4 (D.hardline <> D.joinWith D.hardline (bindings ++ [inner])) <> D.hardline <> D.text "}") :
            [D.text "{" <> D.nest 4 (D.softline <> step) <> D.softline <> D.text "}" | step <- steps]))
    render term = case expressionNode term of
      AllPayloads value predicates -> do
        argument <- render value
        ref <- reference (expressionType value)
        callbacks <- mapM (\(binder,predicate) -> do
          body <- render predicate
          pure (D.text "java.util.function.Function " <>
            D.text "{" <> D.nest 4 (D.softline <>
              D.text (local (binderId binder) ++ " ->") <> D.softline <> body) <>
            D.softline <> D.text "}")) predicates
        pure (call "_schema.allPayloads"
          [ref,argument,call "listOf" callbacks,width,D.text "symbols"])
      AllElements value binder predicate -> do
        argument <- render value
        body <- render predicate
        pure (runtime "allElements" [argument,
          D.text "{" <> D.nest 4 (D.softline <>
            D.text (local (binderId binder) ++ " ->") <> D.softline <> body) <> D.softline <> D.text "}"])
      Local identity -> pure (D.text (local identity))
      Constant value -> scalarLiteral (expressionType term) value >>= checked declarations bits (expressionType term)
      Construct tag args -> do
        values <- mapM render args
        if Native.requiresSchema declarations (expressionType term) then do
          ref <- reference (expressionType term)
          pure (call "LawSpecKotlinCodecs.construct"
            [D.text "_schema",ref,quoted (idText tag),call "listOf" values,width,D.text "symbols"])
        else pure (runtime "construct" [key (expressionType term),quoted (idText tag),array values])
      ExternalCall _ args -> mapM render args >>= external term
      Convert mode target value -> do
        argument <- render value
        case mode of
          CheckedArgument -> checked declarations bits target argument
          Explicit -> pure (runtime "helper" [key target,array [argument],width])
      If c a b -> do
        condition <- render c
        yes <- render a
        no <- render b
        pure (D.group (D.text "(if (" <> runtime "truth" [condition] <> D.text ")" <> D.nest 4 (D.softline <> yes) <>
          D.softline <> D.text "else" <> D.nest 4 (D.softline <> no) <> D.text ")"))
      ShortCircuit op a b -> do
        left <- render a
        right <- render b
        pure (runtime "bool" [D.group (runtime "truth" [left] <>
          D.text (if op == And then " &&" else " ||") <>
          D.nest 4 (D.softline <> runtime "truth" [right]))])
      Unary Not value -> do
        argument <- render value
        pure (runtime "bool" [D.text "!" <> runtime "truth" [argument]])
      Unary Negate value -> do
        argument <- render value
        pure (runtime "helper" [quoted "negate",array [argument],width])
      Binary op _ a b -> do
        left <- render a
        right <- render b
        if Native.requiresSchema declarations (expressionType a) then do
          ref <- reference (expressionType a)
          pure (runtime "bool" [(if op == NotEqual then D.text "!" else mempty) <>
            call "_schema.equal" [ref,left,right,width,D.text "symbols"]])
        else pure (runtime "binary" [quoted (binaryName op),left,right])
      Helper Concurrently [value] -> render value
      Helper builtin args -> do
        values <- mapM render args
        pure (runtime "helper" [quoted (builtinName builtin),array values,width])
      Match scrutinee branches -> do
        value <- render scrutinee
        ref <- reference (expressionType scrutinee)
        arms <- mapM branch branches
        let fallback = D.text "else -> " <> D.block 4
              (D.text "throw " <> call "IllegalArgumentException"
                [quoted "invalid checked match constructor"])
            body = D.text "when (_tag) " <> D.block 4 (D.joinWith D.hardline (arms ++ [fallback]))
        pure (D.multiline (call "LawSpecKotlinCodecs.match" [D.text "_schema",ref,value,width,D.text "symbols"] <>
          D.text " { _tag, _fields ->" <> D.nest 4 (D.hardline <> body) <> D.hardline <> D.text "}"))
    branch matched = do
      body <- render (caseBody matched)
      let bindings = [D.text ("val " ++ local (binderId binder) ++ " = _fields[" ++ show index ++ "]")
            | (index,binder) <- zip [0::Int ..] (caseBinders matched)]
      pure (quoted (idText (caseConstructor matched)) <> D.text " -> " <>
        D.block 4 (D.joinWith D.hardline (bindings ++ [body])))
