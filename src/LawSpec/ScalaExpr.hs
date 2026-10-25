-- | Scala expression documents over checked Core. Native calls are supplied by
-- the consumer so definitions and adapter bridges retain their own ABI. The
-- generated object names its schema Schema and its machine width
-- MachineBits; layout is scalafmt's (LawSpec.ScalaLayout).
module LawSpec.ScalaExpr (renderExpression, scalarLiteral, call, array, reference, quoted, checked, codec, lambda, valueType, schemaName, bitsName) where

import LawSpec.Core
import qualified LawSpec.ScalaData as Native
import qualified LawSpec.JavaData as Java
import LawSpec.Scalar
import qualified LawSpec.Code.Doc as D
import qualified LawSpec.ScalaLayout as L
import LawSpec.JvmLets (flattenLets)

-- | Strings are escaped for Scala here, once, so no generated literal can end
-- early or change meaning.
quoted :: String -> D.Doc
quoted = L.scalaString

-- | The generated object's schema and machine width.
schemaName, bitsName :: String
schemaName = "Schema"
bitsName = "MachineBits"

-- | Arguments wrap one a line when a call is too wide, as scalafmt wraps
-- them. ref:DEC-readable-output-default
call :: String -> [D.Doc] -> D.Doc
call = L.call

-- | The runtime's dynamic value.
valueType :: String
valueType = "LawSpecRuntime.Value"

-- | Arrays of runtime values, for the Java runtime's array parameters.
array :: [D.Doc] -> D.Doc
array = call ("Array[" ++ valueType ++ "]")

-- | A function literal with typed parameters, which Scala converts to the Java
-- functional interface a runtime method expects.
-- A space before ':' keeps it separate from identifiers ending in '_'.
lambda :: [(String, String)] -> D.Doc -> D.Doc
lambda parameters body = D.group (D.text ("(" ++ commaList [n ++ (if last n == '_' then " : " else ": ") ++ t | (n, t) <- parameters] ++ ") =>") <>
  D.nest 2 (D.softline <> body))
  where commaList = foldr1' (\a b -> a ++ ", " ++ b)
        foldr1' _ [] = ""
        foldr1' f xs = foldr1 f xs

-- | Runtime checks name a type by a schema reference built from Core.
reference :: Type -> Either String D.Doc
reference = Native.scalaTypeReferenceDoc

-- | Values of types with a schema are validated as they enter a law, so an
-- adapter cannot return a value outside its declared domain.
-- ref:DEC-portable-exact-arithmetic
checked :: [DataDeclaration] -> Int -> Type -> D.Doc -> Either String D.Doc
checked declarations bits ty value
  | Native.requiresSchema declarations ty = do
      ref <- reference ty
      pure (call (schemaName ++ ".validate") [ref,value,D.text bitsName,D.text "symbols"])
  | otherwise = const (pure (call "LawSpecRuntime.convert"
      [quoted (Java.javaDataKey ty),value,D.text bitsName])) bits

-- | A codec converts between the generated Scala type and the runtime value,
-- checking the value as it goes.
codec :: [DataDeclaration] -> Int -> Type -> Either String D.Doc
codec declarations bits =
  -- Applied to the declarations once, it shares the codec maker's registry
  -- and names across types.
  let codecFor = Native.scalaCodecDocIn (schemaName, bitsName) (D.text "symbols") declarations
  in const codecFor bits

-- | Literals become runtime values built from their declared type and exact
-- digits, so Scala never reads a number at its own precision.
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
    call "Array[Int]" (map (D.text . show) units)])
  SSymbol identity description -> pure (runtime "symbol" [quoted identity,quoted description,D.text "symbols"])
  SAbsent name -> pure (runtime "absent" [quoted name])
  SPresent name payload -> do
    let inner = case ty of Constructor _ [TypeArgument t] -> t; _ -> ty
    valueDoc <- maybe (pure (D.text "null")) (scalarLiteral inner) payload
    pure (runtime "present" [quoted (case ty of Constructor _ [_] -> Java.javaDataKey ty; _ -> name),valueDoc])
  where runtime name = call ("LawSpecRuntime." ++ name)

-- | Expressions are rendered from Core, never from source, so the Scala tests
-- check the same expansion as every other target.
-- ref:DEC-typed-core-boundary
renderExpression :: [DataDeclaration] -> Int -> (Id -> String)
  -> (Expr -> [D.Doc] -> Either String D.Doc) -> Expr -> Either String D.Doc
renderExpression declarations bits local external = render . flattenLets
  where
    width = const (D.text bitsName) bits
    key = quoted . Java.javaDataKey
    runtime name = call ("LawSpecRuntime." ++ name)
    render term
      -- An all group's steps run side by side, each on a virtual thread.
      | Just (fields,binders,body) <- concurrentGroup term = do
          steps <- mapM render fields
          inner <- render body
          let resultsName = "group" ++ show (length (show term))
              bindings = [D.text ("val " ++ local (binderId binder) ++ " = " ++ resultsName ++ ".get(" ++ show i ++ ")")
                | (i,binder) <- zip [0::Int ..] binders]
          pure (runtime "concurrently" ((D.text ("(" ++ resultsName ++ ": java.util.List[" ++ valueType ++ "]) => {") <>
            D.nest 2 (D.hardline <> D.joinWith D.hardline (bindings ++ [inner])) <> D.hardline <> D.text "}") :
            [D.group (D.text "() =>" <> D.nest 2 (D.softline <> step)) | step <- steps]))
    render term = case expressionNode term of
      -- Field nodes are lowered to matches before any backend (lowerFieldNodes).
      Project {} -> Left "a field node reached the backend"
      Update {} -> Left "a record update node reached the backend"
      AllPayloads value predicates -> do
        argument <- render value
        ref <- reference (expressionType value)
        callbacks <- mapM (\(binder,predicate) -> do
          body <- render predicate
          pure (lambda [(local (binderId binder), valueType)] body)) predicates
        pure (call (schemaName ++ ".allPayloads")
          [ref,argument,call ("java.util.List.of[java.util.function.Function[" ++ valueType ++ ", " ++ valueType ++ "]]") callbacks,width,D.text "symbols"])
      AllElements value binder predicate -> do
        argument <- render value
        body <- render predicate
        pure (runtime "allElements" [argument, lambda [(local (binderId binder), valueType)] body])
      SearchElements universal value binder predicate -> do
        argument <- render value
        body <- render predicate
        pure (runtime "searchElements" [D.text (if universal then "true" else "false"), argument,
          lambda [(local (binderId binder), valueType)] body])
      Local identity -> pure (D.text (local identity))
      -- let x = e in body: e runs first, once.
      -- A chain of lets is a block of declarations in one callback, which
      -- the shared JVM helper keeps a bytecode method of its own.
      Let {} -> do
        let chained e = case expressionNode e of
              Let b v rest -> let (steps, final) = chained rest in ((b, v) : steps, final)
              _ -> ([], e)
            (steps, final) = chained term
        declarations <- mapM (\(binder, value) -> L.bind (local (binderId binder)) <$> render value) steps
        inner <- render final
        pure (L.trailing (D.text "LawSpecRuntime.block") ["()"] (declarations ++ [inner]))
      -- A text literal is already its type's value.
      Constant value@(SSequence n _) | n `elem` ["Text", "Utf16Text", "CodePointText"],
        expressionType term == scalarType n -> scalarLiteral (expressionType term) value
      Constant value -> scalarLiteral (expressionType term) value >>= checked declarations bits (expressionType term)
      Construct tag args -> do
        values <- mapM render args
        if Native.requiresSchema declarations (expressionType term) then do
          ref <- reference (expressionType term)
          pure (call "LawSpecScalaCodecs.construct"
            [D.text schemaName,ref,quoted (idText tag),call "List" values,width,D.text "symbols"])
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
          CheckedArgument -> checked declarations bits target argument
          Explicit -> pure (runtime "helper" [key target,array [argument],width])
      If c a b -> do
        condition <- render c
        yes <- render a
        no <- render b
        -- Branches that are blocks keep their braces on the if's lines.
        let block doc = take 1 (D.render D.Compact doc) == "{"
        pure (if block yes || block no
          then L.condition "if" (runtime "truth" [condition]) <> D.text " " <> yes <> D.text " else " <> no
          else D.group (L.condition "if" (runtime "truth" [condition]) <> D.nest 2 (D.softline <> yes) <>
            D.softline <> D.text "else" <> D.nest 2 (D.softline <> no)))
      -- A chain of one operator is one condition, broken after each.
      ShortCircuit op _ _ -> do
        operands <- mapM render (chainOf op term)
        -- scalafmt's search gives up on a long infix chain, so a long one
        -- is a call trying each condition in turn.
        pure (runtime "bool" [case map (\o -> runtime "truth" [o]) operands of
          conditions | length conditions > 8 ->
            call (if op == And then "LawSpecScala.allOf" else "LawSpecScala.anyOf") (map (L.arrow "()") conditions)
          first : rest -> D.group (first <> D.nest 2 (mconcat [D.text (if op == And then " &&" else " ||") <> D.softline <> o | o <- rest]))
          [] -> D.text "true"])
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
            call (schemaName ++ ".equal") [ref,left,right,width,D.text "symbols"]])
        else pure (runtime "binary" [quoted (binaryName op),left,right])
      Helper Concurrently [value] -> render value
      Helper builtin args -> do
        values <- mapM render args
        pure (runtime "helper" [quoted (builtinName builtin),array values,width])
      Match scrutinee branches -> do
        value <- render scrutinee
        ref <- reference (expressionType scrutinee)
        arms <- mapM branch branches
        let fallback = D.text "case _ =>" <> D.nest 2 (D.hardline <> D.text "throw " <> call "IllegalArgumentException"
              [quoted "invalid checked match constructor"])
            body = D.text "tag match " <> D.block 2 (D.joinWith D.hardline (arms ++ [fallback]))
            matching scrutineeDoc = D.multiline (L.callThen "LawSpecScalaCodecs.matching" [D.text schemaName,ref,scrutineeDoc,width,D.text "symbols"]
              (D.text " { (tag, fields) =>" <> D.nest 2 (D.hardline <> body) <> D.hardline <> D.text "}"))
        -- A computed scrutinee is bound first, so matches do not nest in
        -- each other's arguments.
        pure $ case expressionNode scrutinee of
          Local _ -> matching value
          _ -> L.block [L.bind "scrutinee" value, matching (D.text "scrutinee")]
    chainOf op e = case expressionNode e of
      ShortCircuit op' a b | op' == op -> chainOf op a ++ chainOf op b
      _ -> [e]
    branch matched = do
      body <- render (caseBody matched)
      let bindings = [D.text ("val " ++ local (binderId binder) ++ " = fields(" ++ show index ++ ")")
            | (index,binder) <- zip [0::Int ..] (caseBinders matched)]
      -- A body that is a block is the arm's block, not one inside it.
      pure (D.text ("case " ++ Native.scalaQuoted (idText (caseConstructor matched)) ++ " => ") <>
        if null bindings && take 1 (D.render D.Compact body) == "{" then body
        else D.block 2 (D.joinWith D.hardline (bindings ++ [body])))
