-- | Typed expression documents shared by Java tests and reusable definitions.
module LawSpec.JavaExpr (renderExpression, renderExpressionWithContext, scalarLiteral, call, array, reference, quoted, javaDataKey) where

import LawSpec.Core
import qualified LawSpec.Core.Schema as Schema
import LawSpec.Scalar
import qualified LawSpec.Code.Doc as D
import Data.Aeson (encode)
import qualified Data.Text.Lazy as T
import qualified Data.Text.Lazy.Encoding as T
import Data.List (find)

-- | Strings are escaped for Java here, once, so no generated literal can end
-- early or change meaning.
quoted :: String -> D.Doc
quoted value = case chunks value of
  [] -> token ""
  first:rest -> D.group (token first <> D.nest 4
    (mconcat [D.softline <> D.text "+ " <> token part | part <- rest]))
  where
    encoded = T.unpack . T.decodeUtf8 . encode
    token = D.text . encoded
    chunks "" = []
    chunks remaining
      | length (encoded remaining) <= 48 = [remaining]
      | otherwise =
          let candidates = takeWhile (\n -> length (encoded (take n remaining)) <= 42) [1 .. length remaining]
              width = case reverse candidates of n:_ -> n; [] -> 1
              boundary = case reverse [i | (i,c) <- zip [0..] (take width remaining), c == ' ', i >= 16] of
                n:_ -> n
                [] -> width
              (part,rest) = splitAt boundary remaining
          in part : chunks rest

-- | Arguments wrap when a call is too wide, in the Java style LawSpec follows.
-- ref:DEC-readable-output-default
call :: String -> [D.Doc] -> D.Doc
call name args = D.group (D.text (name ++ "(") <>
  D.nest 4 (D.softbreak <> D.group (D.commaSep args)) <> D.text ")")

-- | Lists of runtime values are written in one shape so they wrap like calls.
array :: [D.Doc] -> D.Doc
array values = D.group (D.text "new Value[] {" <>
  D.nest 2 (D.softbreak <> D.group (D.commaSep values)) <> D.softbreak <> D.text "}")

-- | Runtime checks name a type by a schema reference built from Core.
reference :: Type -> Either String D.Doc
reference ty = render <$> Schema.typeReference [] ty
  where
    render (Schema.Parameter _) = error "unbound concrete Java type reference"
    render (Schema.Named name args) = call "new lawspec.runtime.LawSpecSchema.Named"
      (quoted name : map render args)

-- | Literals become runtime values built from their declared type and exact
-- digits, so Java never reads a number at its own precision.
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
    D.group (D.text "new int[] {" <> D.nest 2 (D.softbreak <>
      D.flow [D.text (show unit ++ if index < length units - 1 then "," else "") | (index,unit) <- zip [0::Int ..] units]) <> D.softbreak <> D.text "}")])
  SSymbol identity description -> pure (runtime "symbol" [quoted identity,quoted description,D.text "symbols"])
  SAbsent name -> pure (runtime "absent" [quoted name])
  SPresent name payload -> do
    let inner = case ty of Constructor _ [TypeArgument t] -> t; _ -> ty
    valueDoc <- maybe (pure (D.text "null")) (scalarLiteral inner) payload
    pure (runtime "present" [quoted (case ty of Constructor _ [_] -> javaDataKey ty; _ -> name),valueDoc])
  where runtime name = call ("LawSpecRuntime." ++ name)

-- | Expressions are rendered from Core, never from source, so the Java tests
-- check the same expansion as every other target.
-- ref:DEC-typed-core-boundary
renderExpression :: [DataDeclaration] -> Int -> (Id -> String)
  -> (Expr -> [D.Doc] -> Either String D.Doc) -> Expr -> Either String D.Doc
renderExpression declarations bits = renderExpressionWithContext declarations
  (D.text (show bits)) reference (pure . quoted . javaDataKey)

-- | Callers whose generated code already holds the machine width and type
-- references in scope pass them in, so the rendering refers to them by name.
renderExpressionWithContext :: [DataDeclaration] -> D.Doc -> (Type -> Either String D.Doc)
  -> (Type -> Either String D.Doc) -> (Id -> String)
  -> (Expr -> [D.Doc] -> Either String D.Doc) -> Expr -> Either String D.Doc
renderExpressionWithContext declarations bits reference typeKey local external = render
  where
    runtime name = call ("LawSpecRuntime." ++ name)
    custom (Constructor name args) = any ((== Id name) . dataId) declarations ||
      any (\a -> case a of TypeArgument t -> custom t; _ -> False) args
    custom (TypeVariable _) = True
    custom _ = False
    checked ty value | custom ty = do
      ref <- reference ty
      pure (call "_schema.validate" [ref,value,bits,D.text "symbols"])
    checked ty value = do
      key <- typeKey ty
      pure (runtime "convert" [key,value,bits])
    render term
      -- An all group's steps run side by side, each on a virtual thread.
      | Just (fields,binders,body) <- concurrentGroup term = do
          steps <- mapM render fields
          inner <- render body
          let resultsName = "_group" ++ show (length (show term))
              bindings = [D.text ("var " ++ local (binderId binder) ++ " = " ++ resultsName ++ ".get(" ++ show i ++ ");")
                | (i,binder) <- zip [0::Int ..] binders]
          pure (runtime "concurrently" ((D.text (resultsName ++ " -> ") <>
            D.block 2 (D.joinWith D.hardline (bindings ++ [D.text "return " <> inner <> D.text ";"]))) :
            [D.group (D.text "() ->" <> D.nest 4 (D.softline <> step)) | step <- steps]))
    render term = case expressionNode term of
      AllPayloads value predicates -> do
        argument <- render value
        ref <- reference (expressionType value)
        callbacks <- mapM (\(binder,predicate) -> do
          body <- render predicate
          pure (D.group (D.text (local (binderId binder) ++ " ->") <>
            D.nest 4 (D.softline <> body)))) predicates
        pure (call "_schema.allPayloads"
          [ref,argument,call "java.util.List.of" callbacks,bits,D.text "symbols"])
      AllElements value binder predicate -> do
        argument <- render value
        body <- render predicate
        pure (runtime "allElements" [argument,
          D.group (D.text (local (binderId binder) ++ " ->") <>
            D.nest 4 (D.softline <> body))])
      Constant value -> literal (expressionType term) value >>= checked (expressionType term)
      Local identity -> pure (D.text (local identity))
      -- let x = e in body: e runs first, once.
      Let binder value body -> do
        argument <- render value
        inner <- render body
        pure (runtime "let" [argument, D.group (D.text (local (binderId binder) ++ " ->") <> D.nest 4 (D.softline <> inner))])
      Construct tag args -> do
        values <- mapM render args
        if custom (expressionType term) && idText tag `notElem` ["List::Nil","List::Cons"]
          then do
            ref <- reference (expressionType term)
            pure (call "_schema.construct" [ref,quoted (idText tag),call "java.util.List.of" values,bits,D.text "symbols"])
          else do
            key <- typeKey (expressionType term)
            pure (runtime "construct" [key,quoted (idText tag),array values])
      ExternalCall _ args -> mapM render args >>= external term
      -- Ability nodes go to the caller, which knows where handlers are.
      Perform _ args -> mapM render args >>= external term
      Handle _ body -> render body >>= external term . pure
      Calls _ args -> mapM render (maybe [] id args) >>= external term
      Convert mode target value -> do
        argument <- render value
        if target == expressionType value then pure argument
        else case mode of
          CheckedArgument -> checked target argument
          Explicit -> do
            key <- typeKey target
            pure (runtime "helper" [key,array [argument],bits])
      Binary op _ a b -> do
        left <- render a
        right <- render b
        if custom (expressionType a) then do
          ref <- reference (expressionType a)
          pure (runtime "bool" [(if op == NotEqual then D.text "!" else mempty) <>
            call "_schema.equal" [ref,left,right,bits,D.text "symbols"]])
        else pure (runtime "binary" [quoted (binaryName op),left,right])
      Unary Not value -> do
        argument <- render value
        pure (runtime "bool" [D.text "!" <> runtime "truth" [argument]])
      Unary Negate value -> do
        argument <- render value
        pure (runtime "helper" [quoted "negate",array [argument],bits])
      If c a b -> do
        condition <- render c
        yes <- render a
        no <- render b
        pure (D.group (D.text "(" <> D.nest 4 (runtime "truth" [condition] <> D.softline <> D.text "? " <> yes <>
          D.softline <> D.text ": " <> no) <> D.text ")"))
      ShortCircuit op a b -> do
        left <- render a
        right <- render b
        pure (runtime "bool" [D.group (D.nest 4 (runtime "truth" [left]) <>
          D.nest 4 (D.softline <> D.text (if op == And then "&& " else "|| ") <> runtime "truth" [right]))])
      Helper Concurrently [value] -> render value
      Helper builtin args -> do
        values <- mapM render args
        pure (runtime "helper" [quoted (builtinName builtin),array values,bits])
      Match scrutinee branches -> do
        -- Values are checked where they are built, decoded or drawn.
        value <- render scrutinee
        let dataName = "_match" ++ show (length (show term))
        case expressionType scrutinee of
          Constructor name _ | any ((== Id name) . dataId) declarations -> do
            ref <- reference (expressionType scrutinee)
            arms <- mapM (dataBranch dataName) branches
            let body = D.text "switch (" <> D.text dataName <> D.text ".tag()) " <>
                  D.block 2 (D.joinWith D.hardline
                    (arms ++ [D.group (D.text "default ->" <> D.nest 4 (D.softline <> D.text "throw new IllegalArgumentException(\"invalid constructor\");"))]))
            pure (call "_schema.match" [ref,value,bits,D.text "symbols",
              D.text (dataName ++ " ->") <> D.nest 4 (D.hardline <> body)])
          Constructor name _ -> do
            (helper,tags) <- case name of
              "List" -> pure ("matchList",["List::Nil","List::Cons"])
              "Maybe" -> pure ("matchMaybe",["Maybe::Nothing","Maybe::Just"])
              "Either" -> pure ("matchEither",["Either::Left","Either::Right"])
              _ -> Left "unsupported Java match"
            cases <- mapM (branch branches) tags
            pure (runtime helper (value:cases))
          _ -> Left "matching requires a data type"
    literal ty (SPresent name payload) = do
      let inner = case ty of Constructor _ [TypeArgument t] -> t; _ -> ty
      value <- maybe (pure (D.text "null")) (literal inner) payload
      key <- case ty of Constructor _ [_] -> typeKey ty; _ -> pure (quoted name)
      pure (runtime "present" [key,value])
    literal ty value = scalarLiteral ty value
    branch branches tag = case find ((== Id tag) . caseConstructor) branches of
      Nothing -> Left "non-exhaustive Java match"
      Just matched -> do
        body <- render (caseBody matched)
        let names = map (D.text . local . binderId) (caseBinders matched)
            parameters = case names of
              [name] -> name
              _ -> D.text "(" <> D.joinWith (D.text ", ") names <> D.text ")"
        pure (D.group (parameters <> D.text " ->" <> D.nest 4 (D.softline <> body)))
    dataBranch dataName matched = do
      body <- render (caseBody matched)
      let bindings = [D.text ("var " ++ local (binderId binder) ++ " = " ++ dataName ++
            ".fields().get(" ++ show i ++ ");") | (i,binder) <- zip [0::Int ..] (caseBinders matched)]
      pure (D.text "case " <> quoted (idText (caseConstructor matched)) <> D.text " -> " <>
        D.block 2 (D.joinWith D.hardline (bindings ++ [D.text "yield " <> body <> D.text ";"])))

-- | Java runtime data is keyed by a type's text, nested arguments included, so
-- List Int8 and List Int16 stay apart.
javaDataKey :: Type -> String
javaDataKey (Constructor name args) = case [t | TypeArgument t <- args] of
  [] -> name
  [t] | name `elem` ["List", "Maybe", "Nullable", "Optional"] -> name ++ " " ++ javaDataKey t
  types -> name ++ concatMap (\t -> " (" ++ javaDataKey t ++ ")") types
javaDataKey ty = show ty

