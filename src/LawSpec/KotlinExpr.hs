-- | Kotlin expression documents over checked Core. Native calls are supplied by
-- the consumer so definitions and adapter bridges retain their own ABI.
module LawSpec.KotlinExpr (renderExpression, renderExpressionIn, scalarLiteral, call, array, reference, quoted, checked, checkedIn, codec, codecIn) where

import LawSpec.Core
import qualified LawSpec.KotlinData as Native
import qualified LawSpec.JavaData as Java
import LawSpec.Scalar
import qualified LawSpec.Code.Doc as D
import qualified LawSpec.KotlinLayout as L

-- | Strings are Kotlin literals ($ escaped), never split: ktfmt leaves a
-- long one whole. ref:DEC-native-string-literals
quoted :: String -> D.Doc
quoted = L.kotlinString

-- | Arguments wrap as ktfmt wraps them. ref:DEC-readable-output-default
call :: String -> [D.Doc] -> D.Doc
call = L.call

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
checked declarations bits = checkedIn ("_schema", D.text (show bits)) declarations

-- | As checked, with the schema and machine width under the caller's names.
checkedIn :: (String, D.Doc) -> [DataDeclaration] -> Type -> D.Doc -> Either String D.Doc
checkedIn (schema, width) declarations ty value
  | Native.requiresSchema declarations ty = do
      ref <- reference ty
      pure (call (schema ++ ".validate") [ref,value,width,D.text "symbols"])
  | otherwise = pure (call "LawSpecRuntime.convert"
      [quoted (Java.javaDataKey ty),value,width])

-- | A codec converts between the generated Kotlin type and the runtime value,
-- checking the value as it goes.
codec :: [DataDeclaration] -> Int -> Type -> Either String D.Doc
codec declarations bits =
  -- Applied to the declarations once, it shares the codec maker's registry
  -- and names across types.
  let codecFor = Native.kotlinCodecDocWithContext (D.text "symbols") declarations
  in \ty -> do
  value <- codecFor ty
  pure (D.multiline (D.text "run " <> D.block 4 (D.joinWith D.hardline
    [D.text "val schema = _schema",D.text ("val bits = " ++ show bits),value])))

-- | A codec over the schema and machine width under the caller's names (a
-- test's SCHEMA and MACHINE_BITS).
codecIn :: (String, String) -> [DataDeclaration] -> Type -> Either String D.Doc
codecIn scope declarations = Native.kotlinCodecDocIn scope (D.text "symbols") declarations

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
  -- Text is written as the string it is.
  SSequence name units | name `elem` ["Text", "Utf16Text", "CodePointText"] ->
    pure (runtime "text" [quoted name, quoted (map toEnum units)])
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
renderExpression declarations bits = renderExpressionIn ("_schema", D.text (show bits)) declarations

-- | As renderExpression, with the schema and machine width under the
-- caller's names.
renderExpressionIn :: (String, D.Doc) -> [DataDeclaration] -> (Id -> String)
  -> (Expr -> [D.Doc] -> Either String D.Doc) -> Expr -> Either String D.Doc
renderExpressionIn scope@(schema, width) declarations local external = render
  where
    checked' = checkedIn scope declarations
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
          pure (runtime "concurrently" (L.lambda [resultsName] (bindings ++ [inner]) : [L.lambda [] [step] | step <- steps]))
    render term = case expressionNode term of
      -- Field nodes are lowered to matches before any backend (lowerFieldNodes).
      Project {} -> Left "a field node reached the backend"
      Update {} -> Left "a record update node reached the backend"
      AllPayloads value predicates -> do
        argument <- render value
        ref <- reference (expressionType value)
        callbacks <- mapM (\(binder,predicate) -> do
          body <- render predicate
          pure (D.text "java.util.function.Function " <> L.lambda [local (binderId binder)] [body])) predicates
        pure (call (schema ++ ".allPayloads")
          [ref,argument,call "listOf" callbacks,width,D.text "symbols"])
      AllElements value binder predicate -> do
        argument <- render value
        body <- render predicate
        pure (runtime "allElements" [argument, L.lambda [local (binderId binder)] [body]])
      Local identity -> pure (D.text (local identity))
      -- let x = e in body: e runs first, once.
      Let binder value body -> do
        argument <- render value
        inner <- render body
        -- Kotlin's inline stdlib let expands an entire finite search into
        -- one JVM method. The shared JVM helper preserves the same strict
        -- binding while giving each callback a separate bytecode method.
        pure (runtime "let" [argument, L.lambda [local (binderId binder)] [inner]])
      -- A text literal is already its type's value.
      Constant value@(SSequence n _) | n `elem` ["Text", "Utf16Text", "CodePointText"],
        expressionType term == scalarType n -> scalarLiteral (expressionType term) value
      Constant value -> scalarLiteral (expressionType term) value >>= checked' (expressionType term)
      Construct tag args -> do
        values <- mapM render args
        if Native.requiresSchema declarations (expressionType term) then do
          ref <- reference (expressionType term)
          pure (call "LawSpecKotlinCodecs.construct"
            [D.text schema,ref,quoted (idText tag),call "listOf" values,width,D.text "symbols"])
        else pure (runtime "construct" [key (expressionType term),quoted (idText tag),array values])
      ExternalCall _ args -> mapM render args >>= external term
      -- Ability nodes go to the caller, which knows where handlers are.
      Perform _ args -> mapM render args >>= external term
      Handle _ body -> render body >>= external term . pure
      Calls _ args -> mapM render (maybe [] id args) >>= external term
      Convert mode target value -> do
        argument <- render value
        -- A value already of its target type needs no conversion.
        if target == expressionType value then pure argument else case mode of
          CheckedArgument -> checked' target argument
          Explicit -> pure (runtime "helper" [key target,array [argument],width])
      If c a b -> do
        condition <- render c
        yes <- render a
        no <- render b
        pure (D.group (D.group (D.text "(if (" <> D.nest 4 (D.softbreak <> runtime "truth" [condition]) <> D.softbreak <> D.text ")") <>
          D.nest 4 (D.softline <> yes) <> D.softline <> D.group (D.text "else" <> D.nest 4 (D.softline <> no)) <> D.text ")"))
      -- A chain of one operator is one condition, broken after each.
      ShortCircuit op _ _ -> do
        operands <- mapM render (chainOf op term)
        pure (runtime "bool" [L.operators (if op == And then "&&" else "||") (map (\o -> runtime "truth" [o]) operands)])
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
            call (schema ++ ".equal") [ref,left,right,width,D.text "symbols"]])
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
            body = D.text "when (tag) " <> D.block 4 (D.joinWith D.hardline (arms ++ [fallback]))
        pure (D.multiline (L.callThen "LawSpecKotlinCodecs.match" [D.text schema,ref,value,width,D.text "symbols"]
          (D.text " " <> L.lambda ["tag", "fields"] [body])))
    chainOf op e = case expressionNode e of
      ShortCircuit op' a b | op' == op -> chainOf op a ++ chainOf op b
      _ -> [e]
    branch matched = do
      body <- render (caseBody matched)
      let bindings = [L.bind (local (binderId binder)) (D.group (D.text "fields[" <> D.nest 4 (D.softbreak <> D.text (show index ++ "]"))))
            | (index,binder) <- zip [0::Int ..] (caseBinders matched)]
      pure (quoted (idText (caseConstructor matched)) <> D.text " -> " <>
        D.block 4 (D.joinWith D.hardline (bindings ++ [body])))
