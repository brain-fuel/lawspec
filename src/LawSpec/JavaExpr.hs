-- | Typed expression documents shared by Java tests and reusable definitions.
module LawSpec.JavaExpr (renderExpression, renderExpressionWithContext, renderExpressionWithSchema, scalarLiteral, call, array, reference, referenceIn, quoted, javaDataKey) where

import LawSpec.Core
import qualified LawSpec.Core.Schema as Schema
import LawSpec.Scalar
import qualified LawSpec.Code.Doc as D
import LawSpec.JvmLets (flattenStrictLets)
import LawSpec.JvmNames (jvmString, jvmScopedNames)
import Data.List (find)
import Data.Char (isAlphaNum)
import qualified Data.Map.Strict as M

-- | Strings are Java string literals (LawSpec.Code.Literal), wrapped only
-- at spaces, so no generated literal can end early or change meaning and no
-- word is split. ref:DEC-native-string-literals
-- | A string literal; a long one (a structural record's name, with its
-- hash) is literals joined, split after a :: where the line is too narrow.
quoted :: String -> D.Doc
quoted s = case pieces s of
  first : rest@(_ : _) | length s > 30 ->
    D.group (jvmString "java" first <> D.nest 4 (mconcat [D.softline <> D.text "+ " <> jvmString "java" p | p <- rest]))
  _ -> jvmString "java" s
  where
    -- After each ::, merged while a piece stays within 36 characters; a
    -- longer hash in pieces of 32 and longer text at its spaces, so a
    -- deeply nested line fits.
    pieces = merge . concatMap chunks . cuts
    chunks t
      | length t <= 40 = [t]
      | ' ' `elem` init t = concatMap chunks (afterSpaces t)
      | all (`elem` ("0123456789abcdef: " :: String)) t = takeWhile (not . null) (map (take 32) (iterate (drop 32) t))
      | otherwise = [t]
    -- Text in words, each with the space after it.
    afterSpaces t = case break (== ' ') t of
      (w, ' ' : more) -> (w ++ " ") : afterSpaces more
      (w, _) -> [w | not (null w)]
    cuts t = case breakAfter t of
      (a, []) -> [a]
      (a, b) -> a : cuts b
    breakAfter t = go [] t
      where
        go acc (':' : ':' : more) = (reverse (':' : ':' : acc), more)
        go acc (c : more) = go (c : acc) more
        go acc [] = (reverse acc, [])
    merge (a : b : more) | length a + length b <= 36 = merge ((a ++ b) : more)
    merge (a : more) = a : merge more
    merge [] = []

-- | Arguments wrap when a call is too wide, in the Java style LawSpec follows.
-- ref:DEC-readable-output-default
call :: String -> [D.Doc] -> D.Doc
call name [] = D.text (name ++ "()")
call name args
  -- A long qualified name breaks before its method when its opening does
  -- not fit.
  | length name > 30, (receiver@(_ : _), '.' : method@(_ : _)) <- breakLast name
  , all (\c -> isAlphaNum c || c `elem` ("._" :: String)) name =
      D.prefixChoice (name ++ "(") (plain name) (D.group (D.text receiver <> D.nest 4 (D.softbreak <> plain ("." ++ method))))
  | otherwise = plain name
  where
    plain n = D.group (D.text (n ++ "(") <> D.nest 4 (D.softbreak <> D.group (D.commaSep args)) <> D.text ")")
    breakLast n = let (after, before) = break (== '.') (reverse n) in (reverse (drop 1 before), if null before then [] else '.' : reverse after)

-- | Lists of runtime values are written in one shape so they wrap like calls.
array :: [D.Doc] -> D.Doc
array values = D.group (D.text "new Value[] {" <>
  D.nest 4 (D.softbreak <> D.joinWith (D.text "," <> D.softline) values) <> D.softbreak <> D.text "}")

-- | Runtime checks name a type by a schema reference built from Core.
reference :: Type -> Either String D.Doc
reference = referenceIn "lawspec.runtime.LawSpecSchema.Named"

-- | As reference, naming the class as the generated code imports it.
referenceIn :: String -> Type -> Either String D.Doc
referenceIn named ty = render <$> Schema.typeReference [] ty
  where
    render (Schema.Parameter _) = error "unbound concrete Java type reference"
    render (Schema.Named name args) = call ("new " ++ named)
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
  -- Text is written as the string it is.
  SSequence name units | name `elem` ["Text", "Utf16Text", "CodePointText"] ->
    pure (runtime "text" [quoted name, quoted (map toEnum units)])
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
renderExpressionWithContext = renderExpressionWithSchema "SCHEMA"

-- | As renderExpressionWithContext, with the schema in scope under a name.
renderExpressionWithSchema :: String -> [DataDeclaration] -> D.Doc -> (Type -> Either String D.Doc)
  -> (Type -> Either String D.Doc) -> (Id -> String)
  -> (Expr -> [D.Doc] -> Either String D.Doc) -> Expr -> Either String D.Doc
renderExpressionWithSchema schemaName declarations bits reference typeKey named external expression = render scopedTerm
  where
    -- Java lets no local shadow another in scope, lambdas included, so a
    -- binder whose name an enclosing one holds takes the next free suffix.
    (scopedTerm, scoped) = jvmScopedNames named (flattenStrictLets expression)
    local identity = M.findWithDefault (named identity) identity scoped
    runtime name = call ("LawSpecRuntime." ++ name)
    custom (Constructor name args) = any ((== Id name) . dataId) declarations ||
      any (\a -> case a of TypeArgument t -> custom t; _ -> False) args
    custom (TypeVariable _) = True
    custom _ = False
    checked ty value | custom ty = do
      ref <- reference ty
      pure (call (schemaName ++ ".validate") [ref,value,bits,D.text "symbols"])
    checked ty value = do
      key <- typeKey ty
      pure (runtime "convert" [key,value,bits])
    render term
      -- An all group's steps run side by side, each on a virtual thread.
      | Just (fields,binders,body) <- concurrentGroup term = do
          steps <- mapM render fields
          inner <- render body
          let resultsName = "results" ++ show (length (show term))
              bindings = [D.text ("var " ++ local (binderId binder) ++ " = " ++ resultsName ++ ".get(" ++ show i ++ ");")
                | (i,binder) <- zip [0::Int ..] binders]
          pure (runtime "concurrently" (D.multiline (D.text (resultsName ++ " -> ") <>
            D.block 2 (D.joinWith D.hardline (bindings ++ [D.text "return " <> inner <> D.text ";"]))) :
            [D.group (D.text "() ->" <> D.nest 4 (D.softline <> step)) | step <- steps]))
    render term = case expressionNode term of
      -- Field nodes are lowered to matches before any backend (lowerFieldNodes).
      Project {} -> Left "a field node reached the backend"
      Update {} -> Left "a record update node reached the backend"
      AllPayloads value predicates -> do
        argument <- render value
        ref <- reference (expressionType value)
        callbacks <- mapM (\(binder,predicate) -> do
          body <- render predicate
          pure (D.group (D.text (local (binderId binder) ++ " ->") <>
            D.nest 4 (D.softline <> body)))) predicates
        pure (call (schemaName ++ ".allPayloads")
          [ref,argument,call "java.util.List.of" callbacks,bits,D.text "symbols"])
      AllElements value binder predicate -> do
        argument <- render value
        body <- render predicate
        pure (runtime "allElements" [argument,
          D.group (D.text (local (binderId binder) ++ " ->") <>
            D.nest 4 (D.softline <> body))])
      SearchElements universal value binder predicate -> do
        argument <- render value
        body <- render predicate
        pure (runtime "searchElements" [D.text (if universal then "true" else "false"), argument,
          D.group (D.text (local (binderId binder) ++ " ->") <>
            D.nest 4 (D.softline <> body))])
      -- A text literal is already its type's value.
      Constant value@(SSequence n _) | n `elem` ["Text", "Utf16Text", "CodePointText"],
        expressionType term == scalarType n -> literal (expressionType term) value
      Constant value -> literal (expressionType term) value >>= checked (expressionType term)
      Local identity -> pure (D.text (local identity))
      -- let x = e in body: e runs first, once. A chain of lets is a block
      -- of declarations, as it reads in the law, rather than nested calls.
      Let {} -> do
        let (steps, final) = letChain term
        declarations <- mapM (\(binder, value) -> do
          argument <- render value
          pure (declare (local (binderId binder)) argument)) steps
        inner <- render final
        -- The block's lambda opens on the call's line, so a let costs one level.
        pure (D.multiline (D.text "LawSpecRuntime.block(() -> " <> D.block 2 (D.joinWith D.hardline (declarations ++ [D.text "return " <> inner <> D.text ";"])) <> D.text ")"))
      Construct tag args -> do
        values <- mapM render args
        if custom (expressionType term) && idText tag `notElem` ["List::Nil","List::Cons"]
          then do
            ref <- reference (expressionType term)
            -- The fields come last, so a nested value is indented once per level.
            pure (call (schemaName ++ ".construct") ([ref,quoted (idText tag),bits,D.text "symbols"] ++ values))
          else do
            key <- typeKey (expressionType term)
            -- A list written out is its items, not a cell per item.
            case listItems term of
              Just items | idText tag == "List::Cons" -> do
                rendered <- mapM render items
                pure (runtime "list" [key, call "java.util.List.of" rendered])
              _ -> pure (runtime "construct" [key,quoted (idText tag),array values])
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
            call (schemaName ++ ".equal") [ref,left,right,bits,D.text "symbols"]])
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
      -- A chain of one operator is one condition, broken before each.
      ShortCircuit op _ _ -> do
        operands <- mapM render (shortCircuitChain op term)
        pure (runtime "bool" [case map (\o -> runtime "truth" [o]) operands of
          first : rest -> D.group (first <> D.nest 4 (mconcat [D.softline <> D.text (if op == And then "&& " else "|| ") <> o | o <- rest]))
          [] -> D.text "true"])
      Helper Concurrently [value] -> render value
      Helper builtin args -> do
        values <- mapM render args
        pure (runtime "helper" [quoted (builtinName builtin),array values,bits])
      Match scrutinee branches -> do
        -- Values are checked where they are built, decoded or drawn.
        value <- render scrutinee
        let dataName = "matched" ++ show (length (show term))
        case expressionType scrutinee of
          -- A match that only selects a field of a one-constructor value
          -- is the field.
          Constructor name _ | [d] <- [d | d <- declarations, dataId d == Id name], [_] <- dataConstructors d
                             , [branch] <- branches, Local selected <- expressionNode (caseBody branch)
                             , Just index <- lookup selected (zip (map binderId (caseBinders branch)) [0 :: Int ..]) -> do
            ref <- reference (expressionType scrutinee)
            pure (call (schemaName ++ ".field") [ref, value, quoted (idText (caseConstructor branch)), D.text (show index), bits, D.text "symbols"])
          Constructor name _ | any ((== Id name) . dataId) declarations -> do
            ref <- reference (expressionType scrutinee)
            arms <- mapM (dataBranch dataName) branches
            let body = D.text "switch (" <> D.text dataName <> D.text ".tag())" <> D.hardline <>
                  D.block 2 (D.joinWith D.hardline
                    (arms ++ [D.group (D.text "default ->" <> D.nest 4 (D.softline <> D.text "throw " <> call "new IllegalArgumentException" [quoted "invalid constructor"] <> D.text ";"))]))
            pure (call (schemaName ++ ".match") [ref,value,bits,D.text "symbols",
              D.multiline (D.text (dataName ++ " -> ") <> body)])
          Constructor name _ -> do
            (helper,tags) <- case name of
              "List" -> pure ("matchList",["List::Nil","List::Cons"])
              "Maybe" -> pure ("matchMaybe",["Maybe::Absent","Maybe::Present"])
              "Either" -> pure ("matchEither",["Either::Left","Either::Right"])
              _ -> Left "unsupported Java match"
            cases <- mapM (branch branches) tags
            pure (runtime helper (value:cases))
          _ -> Left "matching requires a data type"
    letChain e = case expressionNode e of
      Let binder value body -> let (steps, final) = letChain body in ((binder, value) : steps, final)
      _ -> ([], e)
    shortCircuitChain op e = case expressionNode e of
      ShortCircuit op' a b | op' == op -> shortCircuitChain op a ++ shortCircuitChain op b
      _ -> [e]
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

-- | The items of a list built from cells, when it ends in the empty list.
listItems :: Expr -> Maybe [Expr]
listItems e = case expressionNode e of
  Construct tag [] | idText tag == "List::Nil" -> Just []
  Construct tag [item, rest] | idText tag == "List::Cons" -> (item :) <$> listItems rest
  _ -> Nothing

-- | var name = value;: a call stays after the = while its opening fits
-- there, breaking its arguments; anything else goes on the next line.
declare :: String -> D.Doc -> D.Doc
declare name value = case break (== '(') flat of
  (opening@(_ : _), '(' : _) | all (\c -> isAlphaNum c || c `elem` ("._<>" :: String)) opening ->
    D.prefixChoice ("var " ++ name ++ " = " ++ opening ++ "(") (D.text ("var " ++ name ++ " = ") <> value <> D.text ";") broken
  _ -> broken
  where
    flat = D.render D.Compact value
    broken = D.group (D.text ("var " ++ name ++ " =") <> D.nest 4 (D.softline <> value)) <> D.text ";"
