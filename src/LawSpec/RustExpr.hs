-- | Typed Core expressions shared by Rust properties and framework-independent
-- definitions. Layout is constructed from tokens, never rewritten source text.
module LawSpec.RustExpr
  ( renderExpression, renderExpressionWithContext, scalarLiteral, presenceValue, quoted, stringLiteral, call, vector, reference, typeName
  , reservedLocals, sourceLocal, sourceLocals, mentions, unusedAs, slice
  , renderExpressionL, scalarExpr, callL, vectorL
  ) where

import LawSpec.Core
import qualified LawSpec.Core.Schema as Schema
import LawSpec.Scalar
import qualified LawSpec.Code.Doc as D
import LawSpec.Code.Literal (literalFor)
import Data.Char (isAlphaNum)
import Data.List (intercalate)
import LawSpec.Naming (localIdentifier, claim, claimAll, scopeWith)
import LawSpec.RustLayout (Arm(..))
import qualified LawSpec.RustLayout as L

-- | Strings are Rust string literals, escaped once by the shared Rust table
-- (LawSpec.Code.Literal), so no generated literal can end early or change
-- meaning. ref:DEC-native-string-literals
quoted :: String -> String
quoted = literalFor "rust"

-- | A string literal is one token: rustfmt never splits it, so neither does
-- LawSpec. Its width is in display columns, as rustfmt counts it.
stringLiteral :: String -> D.Doc
stringLiteral = D.text . quoted

-- | Names generated Rust gives its own temporaries. A source binder never
-- takes one, so no temporary can hide a binder an expression reads.
-- ref:DEC-readable-generated-names
reservedLocals :: [String]
reservedLocals = words "ctx args values case seeds base symbol strategy candidate refinement config result actual expected condition value context ls adapter ls_gen prior draws found pick installing left right accepted fields tag payload payload_member digits coefficient exponent numerator denominator native_result index_target check valid observe score search_case arguments schema checked predicate"

-- | A binder's local: its source name, cased and escaped for Rust, made
-- distinct from the temporaries and from every name already in scope.
sourceLocal :: [(Id,String)] -> Binder -> String
sourceLocal scope binder = fst (claim (scopeWith (reservedLocals ++ map snd scope)) (localIdentifier "rust" (binderName binder)))

-- | Several binders' locals, in order, each distinct from the others.
sourceLocals :: [(Id,String)] -> [Binder] -> [String]
sourceLocals scope binders = fst (claimAll (scopeWith (reservedLocals ++ map snd scope)) (map (localIdentifier "rust" . binderName) binders))

-- | Whether generated code reads a local: one of its identifier tokens,
-- outside string literals, is the name.
mentions :: String -> D.Doc -> Bool
mentions name doc = name `elem` tokens (D.render D.Compact doc)
  where
    tokens [] = []
    tokens ('"' : rest) = tokens (literal rest)
    tokens text@(c : rest)
      | identifierChar c = let (token, after) = span identifierChar text in token : tokens after
      | otherwise = tokens rest
    literal ('\\' : _ : rest) = literal rest
    literal ('"' : rest) = rest
    literal (_ : rest) = literal rest
    literal [] = []
    identifierChar c = isAlphaNum c || c == '_' || c == '#'

-- | A local's binding name: its own when the code after it reads it, else
-- marked unused as Rust marks it, so the build stays free of warnings.
unusedAs :: String -> D.Doc -> String
unusedAs name doc
  | mentions name doc = name
  | otherwise = '_' : dropWhile (== '#') (drop (if take 2 name == "r#" then 2 else 0) name)

orEmpty :: [D.Doc] -> D.Doc -> D.Doc
orEmpty prefix doc = mconcat prefix <> doc

-- | A call of laid-out arguments, broken as rustfmt breaks calls.
-- ref:DEC-readable-output-default
call :: String -> [D.Doc] -> D.Doc
call name values = L.expr (callL name (map L.Laid values))

callL :: String -> [L.Expr] -> L.Expr
callL = L.call

-- | A borrowed array, which wraps as rustfmt wraps arrays.
slice :: [D.Doc] -> D.Doc
slice values = L.expr (L.prefix "&" (L.Macro "" "[" "]" (map L.Laid values)))

-- | Lists of runtime values are written as one vec! so they wrap like calls.
vector :: [D.Doc] -> D.Doc
vector values = L.expr (vectorL (map L.Laid values))

vectorL :: [L.Expr] -> L.Expr
vectorL = L.vecOf

-- | Runtime checks name a type by a schema reference built from Core.
reference :: Type -> Either String D.Doc
reference ty = L.expr . referenceL <$> Schema.typeReference [] ty

referenceL :: Schema.TypeRef -> L.Expr
referenceL ref = case ref of
  Schema.Parameter i -> L.call "ls::TypeRef::Parameter" [L.atom (show i)]
  Schema.Named name args -> L.call "ls::TypeRef::named" [L.atom (quoted name), L.vecOf (map referenceL args)]

-- | Generated Rust names a LawSpec type by its declared name.
typeName :: Type -> String
typeName (Constructor name args) = unwords (name : [typeName t | TypeArgument t <- args])
typeName ty = show ty

-- | Literals become runtime values built from their exact digits, so Rust never
-- reads a number at its own precision.
-- ref:DEC-portable-exact-arithmetic
scalarLiteral :: Scalar -> Either String D.Doc
scalarLiteral scalar = L.expr <$> scalarExpr scalar

scalarExpr :: Scalar -> Either String L.Expr
scalarExpr scalar = case scalar of
  SInteger _ n -> pure (L.call "ls::Value::Integer" [big n])
  SBool value -> pure (L.call "ls::Value::Bool" [L.atom (if value then "true" else "false")])
  SDecimal c e -> pure (exact "Decimal" "ls::Decimal::new" ("coefficient",c) ("exponent",e))
  SRational n d -> pure (exact "Rational" "ls::BigRational::new" ("numerator",n) ("denominator",d))
  SFloat ty bits -> pure (L.call ("ls::Value::" ++ ty)
    [L.call ((if ty == "Float32" then "f32" else "f64") ++ "::from_bits") [L.atom ("0x" ++ bits)]])
  SComplex ty r i -> do
    let component = if ty == "Complex64" then "f32" else "f64"
        variant = if ty == "Complex64" then "Complex32" else "Complex64"
        precision = if ty == "Complex64" then "Float32" else "Float64"
        native (SFloat fieldType bits) | fieldType == precision =
          Right (L.call (component ++ "::from_bits") [L.atom ("0x" ++ bits)])
        native _ = Left "invalid Rust complex literal component precision"
    real <- native r
    imaginary <- native i
    pure (L.call ("ls::Value::" ++ variant) [L.call ("ls::" ++ variant ++ "::new") [real, imaginary]])
  SSequence "Text" units -> pure (L.call "ls::Value::Text" [L.method (L.atom (quoted (map toEnum units))) "to_owned" []])
  SSequence ty units -> pure (L.call ("ls::Value::" ++ ty) [L.vecOf (map (L.atom . show) units)])
  SCharacter "Char" n -> pure (L.call "ls::Value::Char" [L.method (L.call "char::from_u32" [L.atom (show n)]) "unwrap" []])
  SCharacter ty n -> pure (L.call ("ls::Value::" ++ ty) [L.atom (show n)])
  SSymbol identity description -> pure (L.call "ls::Value::Symbol"
    [L.method (L.atom "ctx") "symbol" [L.atom (quoted identity), L.atom (quoted description)]])
  SAbsent name -> pure (L.atom ("ls::Value::" ++ name))
  SPresent name Nothing -> pure (presenceL name Nothing)
  SPresent name (Just value) -> do
    inner <- scalarExpr value
    pure (presenceL name (Just inner))
  where
    exact variant constructor (leftName,left) (rightName,right)
      | nativeInteger left && nativeInteger right = L.call ("ls::Value::" ++ variant) [L.call constructor [big left, big right]]
      | otherwise = L.call ("ls::Value::" ++ variant)
          [L.Block [L.Let leftName (big left), L.Let rightName (big right)] (Just (L.call constructor [L.atom leftName, L.atom rightName]))]
    big n
      | nativeInteger n = L.method (L.atom (if n < 0 then "(" ++ show n ++ "i128)" else show n ++ "i128")) "into" []
      | otherwise = L.Block [L.Let "digits" (L.atom (quoted (show n)))]
          (Just (L.method (L.call "ls::BigInt::parse_bytes" [L.method (L.atom "digits") "as_bytes" [], L.atom "10"]) "unwrap" []))

-- | Whether an integer is written as a native i128.
nativeInteger :: Integer -> Bool
nativeInteger n = n >= negate (2 ^ (127 :: Int)) && n < 2 ^ (127 :: Int)

-- | A named payload keeps nested presence states readable and evaluates each
-- payload exactly once, including Symbol fixture lookups.
presenceValue :: String -> Maybe D.Doc -> D.Doc
presenceValue name value = L.expr (presenceL name (L.Laid <$> value))

presenceL :: String -> Maybe L.Expr -> L.Expr
presenceL name Nothing = L.call ("ls::Value::" ++ name) [L.atom "None"]
presenceL name (Just value) = L.call ("ls::Value::" ++ name)
  [L.Block [L.Let "value" value] (Just (L.call "Some" [L.call "Box::new" [L.atom "value"]]))]

-- | Expressions are rendered from Core, never from source, so the Rust tests
-- check the same expansion as every other target.
-- ref:DEC-typed-core-boundary
renderExpression :: [DataDeclaration] -> Int -> [(Id,String)] -> [(Id,String)] -> Expr -> Either String D.Doc
renderExpression declarations bits callees names term = L.expr <$> renderExpressionL declarations bits callees names term

renderExpressionL :: [DataDeclaration] -> Int -> [(Id,String)] -> [(Id,String)] -> Expr -> Either String L.Expr
renderExpressionL declarations bits = renderWith declarations
  (D.text (show bits)) (D.text "crate::lawspec_schema::schema()?") reference
  (pure . D.text . quoted . typeName)

-- | Schema predicates resolve generic domains using their instantiated arguments.
renderExpressionWithContext :: [DataDeclaration] -> D.Doc -> D.Doc
  -> (Type -> Either String D.Doc) -> (Type -> Either String D.Doc)
  -> [(Id,String)] -> [(Id,String)] -> Expr -> Either String D.Doc
renderExpressionWithContext declarations bits schema typeReference typeKey callees names term =
  L.expr <$> renderWith declarations bits schema typeReference typeKey callees names term

-- | A block of statements and its value; a value that is itself such a
-- block joins it.
blockOf :: [L.Stmt] -> L.Expr -> L.Expr
blockOf ss value = case value of
  L.Block inner tailExpr -> L.Block (ss ++ inner) tailExpr
  _ -> L.Block ss (Just value)

renderWith :: [DataDeclaration] -> D.Doc -> D.Doc
  -> (Type -> Either String D.Doc) -> (Type -> Either String D.Doc)
  -> [(Id,String)] -> [(Id,String)] -> Expr -> Either String L.Expr
renderWith declarations bits schema typeReference typeKey callees = render
  where
    -- A binder never takes a callee's name, which would hide the callee.
    plainCallees = [(i, c) | (i, c) <- callees, ':' `notElem` c, '<' `notElem` c]
    boundLocal names = sourceLocal (names ++ plainCallees)
    boundLocals names = sourceLocals (names ++ plainCallees)
    laid = L.Laid
    tried = L.try'
    okValue = L.call "Ok" [L.atom "value"]
    valueClosure head' inner = L.closure head' (L.Block [L.Let "value" inner] (Just okValue))
    render names term
      -- An all group's steps run side by side as tasks of the Async
      -- ability's default handler (ls::concurrently, the runtime's
      -- NativeAsync), each with its own copy of the context (which shares
      -- the workflow runtime).
      | Just (fields,binders,body) <- concurrentGroup term = do
          let suffix = show (length names)
              contexts = ["group_ctx_" ++ suffix ++ "_" ++ show i | i <- [0 .. length fields - 1]]
              named = boundLocals names binders
              tasks = "group_steps_" ++ suffix
              results = "group_results_" ++ suffix
          steps <- mapM (render names) fields
          inner <- render (zip (map binderId binders) named ++ names) body
          let rendered = L.expr inner
              locals = [unusedAs local rendered | local <- named]
              task (context,step) = L.Semi (L.method (L.atom tasks) "push" [L.call "Box::new"
                [L.closure "|| -> ls::Result<ls::Value>" (L.Block [L.Let "ctx" (L.atom ("&mut " ++ context)), L.Let "value" step] (Just okValue))]])
          pure (L.Block
            ([L.Let ("mut " ++ context) (L.method (L.atom "ctx") "clone" []) | context <- contexts] ++
             [L.Let ("mut " ++ tasks ++ ": Vec<Box<dyn FnOnce() -> ls::Result<ls::Value> + Send + '_>>") (L.call "Vec::new" [])] ++
             map task (zip contexts steps) ++
             [L.Let ("mut " ++ results) (L.method (tried (L.call "ls::concurrently" [L.atom tasks])) "into_iter" [])] ++
             [L.Let local (L.method (L.method (L.atom results) "next" []) "unwrap" []) | local <- locals] ++
             [L.Let "result" inner]) (Just (L.atom "result")))
    render names term = case expressionNode term of
      -- Field nodes are lowered to matches before any backend (lowerFieldNodes).
      Project {} -> Left "a field node reached the backend"
      Update {} -> Left "a record update node reached the backend"
      AllPayloads value predicates -> do
        argument <- render names value
        ref <- typeReference (expressionType value)
        arms <- sequence [do
          let member = boundLocal names binder
          body <- render ((binderId binder,member):names) predicate
          let used = mentions member (L.expr body)
          pure (used, Arm (show index) Nothing (L.Block ([L.Let member (L.atom "payload_member") | used] ++ [L.Let "accepted" body]) (Just (L.call "Ok" [L.atom "accepted"]))))
          | (index,(binder,predicate)) <- zip [0::Int ..] predicates]
        let member = if any fst arms then "payload_member" else "_"
            dispatcher = L.closure ("|payload_index, " ++ member ++ ", ctx|") (L.Match (L.atom "payload_index")
              (map snd arms ++ [Arm "_" Nothing (L.call "Err" [L.method (L.atom (quoted "invalid payload predicate index")) "into" []])]))
        pure (L.Block
          [ L.Let "payload_value" argument
          , L.Let "payload_type" (laid ref)
          , L.Let "payload_schema" (laid schema) ]
          (Just (tried (L.method (L.atom "payload_schema") "all_payloads_with_context"
            [L.atom "payload_value", L.atom "&payload_type", L.atom (show (length predicates)), laid bits, L.atom "ctx", dispatcher]))))
      AllElements value binder predicate -> do
        argument <- render names value
        let name = boundLocal names binder
        body <- render ((binderId binder,name):names) predicate
        pure (L.Block [L.Let "values" argument]
          (Just (tried (L.call "ls::all_elements" [L.atom "values",
            L.closure ("|" ++ unusedAs name (L.expr body) ++ "|") (L.Block [L.Let "accepted" body] (Just (L.call "Ok" [L.atom "accepted"])))]))))
      Constant scalar -> scalarExpr scalar
      -- let x = e in body: e runs first, once.
      Let binder value body -> do
        argument <- render names value
        let name = boundLocal names binder
        inner <- render ((binderId binder,name):names) body
        pure (blockOf [L.Let (unusedAs name (L.expr inner)) argument] inner)
      Local identity -> maybe (Left ("unbound Rust binder: " ++ idText identity))
        (\name -> Right (L.method (L.atom name) "clone" [])) (lookup identity names)
      Construct tag fields -> do
        values <- mapM (render names) fields
        let builtin = idText tag `elem` ["List::Nil","List::Cons","Maybe::Absent","Maybe::Present","Either::Left","Either::Right"]
            construct entries = (if builtin then tried else id)
              (L.call (if builtin then "ls::construct" else "ls::construct_data") [L.atom (quoted (idText tag)), L.vecOf entries])
            -- A field made without statements is written in place.
            inline field = case expressionNode field of
              Constant (SInteger _ n) -> nativeInteger n
              Constant (SDecimal c e) -> nativeInteger c && nativeInteger e
              Constant (SRational n d) -> nativeInteger n && nativeInteger d
              Constant (SPresent _ _) -> False
              Constant _ -> True
              Local _ -> True
              Construct _ inner -> all inline inner
              _ -> False
            locals = ["constructor_field_" ++ show i | i <- [0 :: Int .. length fields - 1]]
        -- Preserve evaluation order and keep block-valued fields out of vec!
        -- argument layouts, whose packing rules differ from ordinary calls.
        pure (if all inline fields then construct values else
          L.Block [L.Let name value | (name,value) <- zip locals values] (Just (construct (map L.atom locals))))
      Match scrutinee branches -> do
        value <- render names scrutinee
        arms <- mapM (branch names) branches
        pure (L.Match value (arms ++ [Arm "_" Nothing (L.Return (Just (L.call "Err" [L.method (L.atom (quoted "invalid match value")) "into" []])))]))
      ExternalCall identity args -> do
        name <- maybe (Left ("unknown Rust declaration: " ++ idText identity)) Right (lookup identity callees)
        values <- mapM (render names) args
        pure (callDoc name (idText identity) args values)
      -- raise aborts to the nearest attempt of its Fail ability (a panic).
      Perform op [value] | isFail (operationAbility op) -> do
        argument <- render names value
        pure (L.Block [L.Let "value" argument] (Just (L.call "ls::raise_failure" [L.atom (quoted (abilityKey (operationAbility op))), L.atom "value"])))
      -- An operation goes to its bridge, which finds the handler installed
      -- in the context for its ability.
      Perform op args -> do
        name <- maybe (Left ("no Rust bridge for the operation " ++ operationName op)) Right (lookup (operationId op) callees)
        values <- mapM (render names) args
        pure (callDoc name (operationName op) args values)
      Handle (CatchFailure ability) body -> do
        inner <- render names body
        pure (tried (L.call "ls::attempt" [L.atom "ctx", L.atom (quoted (abilityKey ability)),
          valueClosure "|ctx: &mut ls::Context| -> ls::Result<ls::Value>" inner,
          L.closure "|value|" (L.call "ls::construct" [L.atom (quoted "Either::Right"), L.vecOf [L.atom "value"]]),
          L.closure "|value|" (L.call "ls::construct" [L.atom (quoted "Either::Left"), L.vecOf [L.atom "value"]])]))
      -- handle e with h end: e runs with h installed for its ability, made
      -- afresh each time.
      Handle (WithHandler ability (SpecHandler h)) body -> do
        made <- maybe (Left ("no Rust spec handler " ++ idText h)) Right (lookup (Id ("handler:" ++ idText h)) callees)
        trait <- maybe (Left ("no Rust trait for " ++ abilityKey ability)) Right (lookup (Id ("trait:" ++ abilityKey ability)) callees)
        inner <- render names body
        pure (L.Block [ L.Let ("handler: std::sync::Arc<dyn " ++ trait ++ ">") (L.call "std::sync::Arc::new" [L.call (made ++ "::new") [L.atom "ctx"]])
                      , L.Let "installing" (L.vecOf [L.Macro "" "(" ")"
            [ L.method (L.atom (quoted (abilityKey ability))) "to_string" []
            , L.call "ls::installed" [L.atom "handler"] ]])]
          (Just (tried (L.call "ls::with_handlers" [L.atom "ctx", L.atom "installing", valueClosure "|ctx: &mut ls::Context| -> ls::Result<ls::Value>" inner]))))
      Handle _ _ -> Left "unknown Rust handling"
      Calls op args -> do
        values <- mapM (render names) (maybe [] id args)
        let expected = ["expected_" ++ show i | i <- [0 .. length values - 1]]
            matcher = case args of
              Nothing -> L.atom "None"
              Just _ -> L.call "Some" [L.prefix "&" (L.closure "|recorded: &[ls::Value]| -> ls::Result<bool>"
                (L.Block [] (Just (L.call "Ok" [foldr1 (L.infixOp "&&") (L.atom "true" `orIfNone`
                  [tried (L.call "ls::equal" [L.atom ("&recorded[" ++ show i ++ "]"), L.atom ("&" ++ e)]) | (i,e) <- zip [0 :: Int ..] expected])]))))]
        pure (L.letIn [L.Let e value | (e,value) <- zip expected values]
          ((tried (L.call "ls::count_calls" [L.atom "ctx", L.atom (quoted (abilityKey (operationAbility op))), L.atom (quoted (operationName op)), matcher]))))
      Binary op evidence a b -> do
        left <- render names a
        right <- render names b
        let domain = case evidence of Numeric ty -> ty; Structural ty -> ty
        key <- typeKey domain
        pure (bound [("left", left), ("right", right)] (\[l, r] -> tried (L.call "ls::binary" [L.atom (quoted (binaryName op)), laid key, l, r])))
      Unary op value -> do
        body <- render names value
        pure (bound [("value", body)] (\[v] -> case op of
          Negate -> tried (L.call "ls::negate" [v])
          Not -> L.call "ls::Value::Bool" [L.prefix "!" (tried (L.method v "boolean" []))]))
      If c a b -> do
        condition <- render names c
        yes <- render names a
        no <- render names b
        pure (bound [("condition", condition)] (\[v] -> L.If (tried (L.method v "boolean" [])) (asBlock yes) (Just (asBlock no))))
      ShortCircuit op a b -> do
        left <- render names a
        right <- render names b
        let (yes,no) = if op == And then (right, L.call "ls::Value::Bool" [L.atom "false"]) else (L.call "ls::Value::Bool" [L.atom "true"], right)
        pure (bound [("left", left)] (\[v] -> L.If (tried (L.method v "boolean" [])) (asBlock yes) (Just (asBlock no))))
      Convert _ target value
        | target == expressionType value -> render names value
        | otherwise -> do
            body <- render names value
            key <- typeKey target
            pure (bound [("value", body)] (\[v] -> tried (L.method v "convert" [laid key, laid bits])))
      Helper Concurrently [value] -> render names value
      Helper builtin args -> do
        values <- mapM (render names) args
        pure (tried (L.call "ls::helper" [L.atom (quoted (builtinName builtin)), L.vecOf values]))
    -- An if's branches are blocks even when they hold only a value.
    asBlock e = case e of
      L.Block _ _ -> e
      _ -> L.Block [] (Just e)
    orIfNone fallback xs = if null xs then [fallback] else xs
    -- A call: its arguments are written in the call when reading them
    -- cannot borrow the context; otherwise each is made first, left to
    -- right, before the call borrows the context. Its error names what
    -- was called.
    callDoc name label args values
      | all simple args = called (L.call name [L.atom "ctx", L.vecOf values])
      | otherwise = L.Block [L.Let argument value | (argument,value) <- zip arguments values]
          (Just (called (L.call name [L.atom "ctx", L.vecOf (map L.atom arguments)])))
      where
        arguments = ["argument_" ++ show i | i <- [1 .. length values]]
        called made = tried (L.call "ls::called" [L.atom (quoted label), made])
        simple a = case expressionNode a of
          Local _ -> True
          Constant (SSymbol _ _) -> False
          Constant (SInteger _ n) -> nativeInteger n
          Constant (SDecimal c e) -> nativeInteger c && nativeInteger e
          Constant (SRational n d) -> nativeInteger n && nativeInteger d
          Constant (SPresent _ _) -> False
          Constant _ -> True
          _ -> False
    branch names matched = do
      let binders = caseBinders matched
          named = boundLocals names binders
      body <- render (zip (map binderId binders) named ++ names) (caseBody matched)
      let locals = [unusedAs name (L.expr body) | name <- named]
          next = L.method (L.method (L.atom "fields") "next" []) "unwrap" []
      (patternText,guard,bindings) <- case (idText (caseConstructor matched), locals) of
        ("Maybe::Absent",[]) -> pure ("ls::Value::Maybe(None)",Nothing,[])
        ("Maybe::Present",[field]) -> pure ("ls::Value::Maybe(Some(payload))",Nothing,[L.Let field (L.atom "*payload")])
        ("Either::Left",[field]) -> pure ("ls::Value::Left(payload)",Nothing,[L.Let field (L.atom "*payload")])
        ("Either::Right",[field]) -> pure ("ls::Value::Right(payload)",Nothing,[L.Let field (L.atom "*payload")])
        ("List::Nil",[]) -> pure ("ls::Value::List(values)",Just (L.method (L.atom "values") "is_empty" []),[])
        ("List::Cons",[first,rest]) -> pure ("ls::Value::List(values)",Just (L.prefix "!" (L.method (L.atom "values") "is_empty" [])),
          [L.Let "mut fields" (L.method (L.atom "values") "into_iter" []), L.Let first next,
           L.Let rest (L.call "ls::Value::List" [L.method (L.atom "fields") "collect" []])])
        (tag,_) | any (any ((== caseConstructor matched) . constructorId) . dataConstructors) declarations ->
          pure ("ls::Value::Data(tag, fields)",
            Just (L.infixOp "&&" (L.infixOp "==" (L.atom "tag") (L.atom (quoted tag))) (L.infixOp "==" (L.method (L.atom "fields") "len" []) (L.atom (show (length locals))))),
            [L.Let "mut fields" (L.method (L.atom "fields") "into_iter" []) | not (null locals)] ++
            [L.Let name next | name <- locals])
        _ -> Left ("no Rust match representation for " ++ idText (caseConstructor matched))
      pure (Arm patternText guard (blockOf bindings body))

-- | Operands used in order: one that is a block is bound to its name
-- first (and so is each before it, keeping the order they are evaluated
-- in); the others are written in place.
bound :: [(String, L.Expr)] -> ([L.Expr] -> L.Expr) -> L.Expr
bound operands use =
  let blocks = [i | (i, (_, v)) <- zip [0 :: Int ..] operands, isBlock v]
      lastBlock = if null blocks then -1 else maximum blocks
      named = [(i <= lastBlock, n, v) | (i, (n, v)) <- zip [0 ..] operands]
      isBlock v = case v of
        L.Block _ _ -> True
        _ -> False
  in L.letIn [L.Let n v | (True, n, v) <- named] (use [if b then L.atom n else v | (b, n, v) <- named])
