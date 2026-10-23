-- | Typed Core expressions shared by Rust properties and framework-independent
-- definitions. Layout is constructed from tokens, never rewritten source text.
module LawSpec.RustExpr
  ( renderExpression, renderExpressionWithContext, scalarLiteral, presenceValue, quoted, stringLiteral, call, vector, reference, typeName
  , reservedLocals, sourceLocal, sourceLocals, mentions, unusedAs, slice
  ) where

import LawSpec.Core
import qualified LawSpec.Core.Schema as Schema
import LawSpec.Scalar
import qualified LawSpec.Code.Doc as D
import LawSpec.Code.Literal (literalFor)
import Data.Char (isAlphaNum)
import Data.List (intercalate)
import LawSpec.Naming (localIdentifier, claim, claimAll, scopeWith)

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

-- | Rustfmt also limits argument and array contents to 60 columns.
delimited :: String -> String -> [D.Doc] -> D.Doc
delimited "vec![" "]" [value] = D.text "vec![" <> D.firstLineWidth 60 value <> D.text "]"
delimited opening closing [value] = D.delimitTrailing 4 opening closing [value]
delimited opening closing values
  | length (intercalate ", " (map (D.render D.Compact) values)) > 60 =
      D.text opening <> D.nest 4 (D.softbreak <>
        D.joinWith D.softline [value <> D.text "," | value <- values]) <>
      D.softbreak <> D.text closing
  | otherwise = D.delimitTrailing 4 opening closing values

-- | Arguments wrap when a call is too wide, in the Rust style LawSpec follows.
-- ref:DEC-readable-output-default
call :: String -> [D.Doc] -> D.Doc
call name values = D.text name <> delimited "(" ")" values
-- | A borrowed array, which wraps as rustfmt wraps arrays.
slice :: [D.Doc] -> D.Doc
slice = delimited "&[" "]"

-- | Lists of runtime values are written as one vec! so they wrap like calls.
vector :: [D.Doc] -> D.Doc
vector = delimited "vec![" "]"

-- | Runtime checks name a type by a schema reference built from Core.
reference :: Type -> Either String D.Doc
reference ty = render False <$> Schema.typeReference [] ty
  where
    render _ (Schema.Parameter i) = call "ls::TypeRef::Parameter" [D.text (show i)]
    render single (Schema.Named name args) =
      let children = case args of
            [child] -> D.text "vec![" <> render True child <> D.text "]"
            _ -> vector (map (render False) args)
          values = [D.text (quoted name),children]
          longElement = single && length (D.render D.Compact (call "ls::TypeRef::named" values)) > 60
      in if longElement
         then D.text "ls::TypeRef::named(" <> D.nest 4 (D.softbreak <>
           D.joinWith D.softline [value <> D.text "," | value <- values]) <> D.softbreak <> D.text ")"
         else call "ls::TypeRef::named" values

-- | Generated Rust names a LawSpec type by its declared name.
typeName :: Type -> String
typeName (Constructor name args) = unwords (name : [typeName t | TypeArgument t <- args])
typeName ty = show ty

-- | Literals become runtime values built from their exact digits, so Rust never
-- reads a number at its own precision.
-- ref:DEC-portable-exact-arithmetic
scalarLiteral :: Scalar -> Either String D.Doc
scalarLiteral scalar = case scalar of
  SInteger _ n
    | nativeInteger n -> pure (call "ls::Value::Integer" [big n])
    | otherwise -> pure (D.text "ls::Value::Integer(" <> big n <> D.text ")")
  SBool value -> pure (call "ls::Value::Bool" [D.text (if value then "true" else "false")])
  SDecimal c e -> pure (exact "Decimal" "ls::Decimal::new" ("coefficient",c) ("exponent",e))
  SRational n d -> pure (exact "Rational" "ls::BigRational::new" ("numerator",n) ("denominator",d))
  SFloat ty bits -> pure (call ("ls::Value::" ++ ty)
    [call ((if ty == "Float32" then "f32" else "f64") ++ "::from_bits") [D.text ("0x" ++ bits)]])
  SComplex ty r i -> do
    let component = if ty == "Complex64" then "f32" else "f64"
        variant = if ty == "Complex64" then "Complex32" else "Complex64"
        precision = if ty == "Complex64" then "Float32" else "Float64"
        native (SFloat fieldType bits) | fieldType == precision =
          Right (call (component ++ "::from_bits") [D.text ("0x" ++ bits)])
        native _ = Left "invalid Rust complex literal component precision"
    real <- native r
    imaginary <- native i
    pure (D.text ("ls::Value::" ++ variant ++ "(") <>
      call ("ls::" ++ variant ++ "::new") [real, imaginary] <> D.text ")")
  SSequence "Text" units -> pure (call "ls::Value::Text" [stringLiteral (map toEnum units) <> D.text ".to_owned()"])
  SSequence ty units -> pure (call ("ls::Value::" ++ ty) [vector (map (D.text . show) units)])
  SCharacter "Char" n -> pure (call "ls::Value::Char"
    [call "char::from_u32" [D.text (show n)] <> D.text ".unwrap()"])
  SCharacter ty n -> pure (call ("ls::Value::" ++ ty) [D.text (show n)])
  SSymbol identity description -> pure (call "ls::Value::Symbol"
    [call "ctx.symbol" [stringLiteral identity,stringLiteral description]])
  SAbsent name -> pure (D.text ("ls::Value::" ++ name))
  SPresent name Nothing -> pure (presenceValue name Nothing)
  SPresent name (Just value) -> do
    inner <- scalarLiteral value
    pure (presenceValue name (Just inner))
  where
    exact variant constructor (leftName,left) (rightName,right)
      | nativeInteger left && nativeInteger right = call ("ls::Value::" ++ variant) [call constructor [big left,big right]]
      | otherwise =
      D.text ("ls::Value::" ++ variant ++ "(") <>
      ( D.block 4 (D.hang 4 (D.text ("let " ++ leftName ++ " =")) (big left) <>
          D.text ";" <> D.hardline <>
          D.hang 4 (D.text ("let " ++ rightName ++ " =")) (big right) <>
          D.text ";" <> D.hardline <> call constructor [D.text leftName,D.text rightName])) <>
      D.text ")"
    big n
      | nativeInteger n =
          D.text ((if n < 0 then "(" ++ show n ++ "i128)" else show n ++ "i128") ++ ".into()")
      | otherwise = D.block 4 (D.hang 4 (D.text "let digits =") (stringLiteral (show n)) <>
          D.text ";" <> D.hardline <>
          D.text "ls::BigInt::parse_bytes(digits.as_bytes(), 10).unwrap()")

-- | Whether an integer is written as a native i128.
nativeInteger :: Integer -> Bool
nativeInteger n = n >= negate (2 ^ (127 :: Int)) && n < 2 ^ (127 :: Int)

-- | A named payload keeps nested presence states readable and evaluates each
-- payload exactly once, including Symbol fixture lookups.
presenceValue :: String -> Maybe D.Doc -> D.Doc
presenceValue name Nothing = call ("ls::Value::" ++ name) [D.text "None"]
presenceValue name (Just value) = D.text ("ls::Value::" ++ name ++ "(") <>
  D.block 4 (D.hang 4 (D.text "let value =") value <> D.text ";" <> D.hardline <>
    D.text "Some(Box::new(value))") <> D.text ")"

-- | Expressions are rendered from Core, never from source, so the Rust tests
-- check the same expansion as every other target.
-- ref:DEC-typed-core-boundary
renderExpression :: [DataDeclaration] -> Int -> [(Id,String)] -> [(Id,String)] -> Expr -> Either String D.Doc
renderExpression declarations bits = renderExpressionWithContext declarations
  (D.text (show bits)) (D.text "crate::lawspec_schema::schema()?") reference
  (pure . D.text . quoted . typeName)

-- | Schema predicates resolve generic domains using their instantiated arguments.
renderExpressionWithContext :: [DataDeclaration] -> D.Doc -> D.Doc
  -> (Type -> Either String D.Doc) -> (Type -> Either String D.Doc)
  -> [(Id,String)] -> [(Id,String)] -> Expr -> Either String D.Doc
renderExpressionWithContext declarations bits schema typeReference typeKey callees = render
  where
    -- A binder never takes a callee's name, which would hide the callee.
    plainCallees = [(i, c) | (i, c) <- callees, ':' `notElem` c, '<' `notElem` c]
    boundLocal names = sourceLocal (names ++ plainCallees)
    boundLocals names = sourceLocals (names ++ plainCallees)
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
          let locals = [unusedAs local inner | local <- named]
          let task (context,step) = D.text (tasks ++ ".push(Box::new(|| -> ls::Result<ls::Value> ") <>
                D.block 4 (D.text ("let ctx = &mut " ++ context ++ ";") <> D.hardline <>
                  D.hang 4 (D.text "let value =") step <> D.text ";" <> D.hardline <> D.text "Ok(value)") <> D.text "));"
          pure (D.block 4 (D.joinWith D.hardline
            ([D.text ("let mut " ++ context ++ " = ctx.clone();") | context <- contexts] ++
             [D.text ("let mut " ++ tasks ++ ": Vec<Box<dyn FnOnce() -> ls::Result<ls::Value> + Send + '_>> = Vec::new();")] ++
             map task (zip contexts steps) ++
             [D.text ("let mut " ++ results ++ " = ls::concurrently(" ++ tasks ++ ")?.into_iter();")] ++
             [D.text ("let " ++ local ++ " = " ++ results ++ ".next().unwrap();") | local <- locals] ++
             [D.hang 4 (D.text "let result =") inner <> D.text ";", D.text "result"])))
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
          let used = mentions member body
          pure (used, D.text (show index ++ " => ") <> D.block 4
            ([D.text ("let " ++ member ++ " = payload_member;") <> D.hardline | used] `orEmpty`
             (D.hang 4 (D.text "let accepted =") body <> D.text ";" <>
              D.hardline <> D.text "Ok(accepted)")))
          | (index,(binder,predicate)) <- zip [0::Int ..] predicates]
        let member = if any fst arms then "payload_member" else "_"
            dispatcher = D.text ("|payload_index, " ++ member ++ ", ctx| ") <>
              D.text "match payload_index " <> D.block 4
                (D.joinWith D.hardline (map snd arms ++
                  [D.text "_ => Err(\"invalid payload predicate index\".into()),"]))
        pure (D.block 4 (D.joinWith D.hardline
          [D.hang 4 (D.text "let payload_value =") argument <> D.text ";",
           D.hang 4 (D.text "let payload_type =") ref <> D.text ";",
           D.hang 4 (D.text "let payload_schema =") schema <> D.text ";",
           call "payload_schema.all_payloads_with_context"
             [D.text "payload_value",D.text "&payload_type",D.text (show (length predicates)),
              bits,D.text "ctx",dispatcher] <> D.text "?"]))
      AllElements value binder predicate -> do
        argument <- render names value
        let name = boundLocal names binder
        body <- render ((binderId binder,name):names) predicate
        pure (D.block 4 (D.hang 4 (D.text "let values =") argument <> D.text ";" <>
          D.hardline <> D.text ("ls::all_elements(values, |" ++ unusedAs name body ++ "| ") <> D.block 4
            (D.hang 4 (D.text "let accepted =") body <> D.text ";" <>
              D.hardline <> D.text "Ok(accepted)") <> D.text ")?"))
      Constant scalar -> scalarLiteral scalar
      -- let x = e in body: e runs first, once.
      Let binder value body -> do
        argument <- render names value
        let name = boundLocal names binder
        inner <- render ((binderId binder,name):names) body
        pure (D.block 4 (D.hang 4 (D.text ("let " ++ unusedAs name inner ++ " =")) argument <> D.text ";" <>
          D.hardline <> inner))
      Local identity -> maybe (Left ("unbound Rust binder: " ++ idText identity))
        (Right . D.text . (++ ".clone()")) (lookup identity names)
      Construct tag fields -> do
        values <- mapM (render names) fields
        let builtin = idText tag `elem` ["List::Nil","List::Cons","Maybe::Absent","Maybe::Present","Either::Left","Either::Right"]
            construct entries = call (if builtin then "ls::construct" else "ls::construct_data")
              [D.text (quoted (idText tag)),vector entries] <> if builtin then D.text "?" else mempty
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
        pure (if all inline fields then construct values else D.block 4
          (D.joinWith D.hardline
            ([D.hang 4 (D.text ("let " ++ name ++ " =")) value <> D.text ";" |
              (name,value) <- zip locals values] ++ [construct (map D.text locals)])))
      Match scrutinee branches -> do
        value <- render names scrutinee
        arms <- mapM (branch names) branches
        pure (D.text "match " <> value <> D.text " " <> D.block 4
          (D.joinWith D.hardline (arms ++ [D.text "_ => return Err(\"invalid match value\".into()),"])))
      ExternalCall identity args -> do
        name <- maybe (Left ("unknown Rust declaration: " ++ idText identity)) Right (lookup identity callees)
        values <- mapM (render names) args
        pure (callDoc name (idText identity) args values)
      -- raise aborts to the nearest attempt of its Fail ability (a panic).
      Perform op [value] | isFail (operationAbility op) -> do
        argument <- render names value
        pure (D.block 4 (D.hang 4 (D.text "let value =") argument <> D.text ";" <> D.hardline <>
          call "ls::raise_failure" [D.text (quoted (abilityKey (operationAbility op))),D.text "value"]))
      -- An operation goes to its bridge, which finds the handler installed
      -- in the context for its ability.
      Perform op args -> do
        name <- maybe (Left ("no Rust bridge for the operation " ++ operationName op)) Right (lookup (operationId op) callees)
        values <- mapM (render names) args
        pure (callDoc name (operationName op) args values)
      Handle (CatchFailure ability) body -> do
        inner <- render names body
        pure (call "ls::attempt" [D.text "ctx",D.text (quoted (abilityKey ability)),
          D.text "|ctx: &mut ls::Context| -> ls::Result<ls::Value> " <> D.block 4 (D.hang 4 (D.text "let value =") inner <> D.text ";" <> D.hardline <> D.text "Ok(value)"),
          D.text "|value| ls::construct(\"Either::Right\", vec![value])",
          D.text "|value| ls::construct(\"Either::Left\", vec![value])"] <> D.text "?")
      -- handle e with h end: e runs with h installed for its ability, made
      -- afresh each time.
      Handle (WithHandler ability (SpecHandler h)) body -> do
        made <- maybe (Left ("no Rust spec handler " ++ idText h)) Right (lookup (Id ("handler:" ++ idText h)) callees)
        trait <- maybe (Left ("no Rust trait for " ++ abilityKey ability)) Right (lookup (Id ("trait:" ++ abilityKey ability)) callees)
        inner <- render names body
        pure (D.block 4 (D.text ("let installing = vec![(" ++ quoted (abilityKey ability) ++ ".to_string(), ls::installed(std::sync::Arc::new(" ++ made ++
            "::new(ctx)) as std::sync::Arc<dyn " ++ trait ++ ">))];") <> D.hardline <>
          call "ls::with_handlers" [D.text "ctx", D.text "installing",
            D.text "|ctx: &mut ls::Context| -> ls::Result<ls::Value> " <> D.block 4 (D.hang 4 (D.text "let value =") inner <> D.text ";" <> D.hardline <> D.text "Ok(value)")] <> D.text "?"))
      Handle _ _ -> Left "unknown Rust handling"
      Calls op args -> do
        values <- mapM (render names) (maybe [] id args)
        let expected = ["expected_" ++ show i | i <- [0 .. length values - 1]]
            bindings = [D.hang 4 (D.text ("let " ++ e ++ " =")) value <> D.text ";" | (e,value) <- zip expected values]
            matcher = case args of
              Nothing -> D.text "None"
              Just _ -> D.text "Some(&|recorded: &[ls::Value]| -> ls::Result<bool> " <> D.block 4
                (D.text ("Ok(" ++ intercalate " && " (["true" | null expected] ++
                  ["ls::equal(&recorded[" ++ show i ++ "], &" ++ e ++ ")?" | (i,e) <- zip [0 :: Int ..] expected]) ++ ")")) <> D.text ")"
        pure (D.block 4 (D.joinWith D.hardline (bindings ++
          [call "ls::count_calls" [D.text "ctx",D.text (quoted (abilityKey (operationAbility op))),D.text (quoted (operationName op)),matcher] <> D.text "?"])))
      Binary op evidence a b -> do
        left <- render names a
        right <- render names b
        let domain = case evidence of Numeric ty -> ty; Structural ty -> ty
        key <- typeKey domain
        pure (D.block 4 (D.text "let left = " <> left <> D.text ";" <> D.hardline <>
          D.text "let right = " <> right <> D.text ";" <> D.hardline <>
          call "ls::binary" [D.text (quoted (binaryName op)),key,D.text "left",D.text "right"] <> D.text "?"))
      Unary op value -> do
        body <- render names value
        pure (D.block 4 (D.text "let value = " <> body <> D.text ";" <> D.hardline <>
          case op of
            Negate -> D.text "ls::negate(value)?"
            Not -> D.text "ls::Value::Bool(!value.boolean()?)"))
      If c a b -> do
        condition <- render names c
        yes <- render names a
        no <- render names b
        pure (D.block 4 (D.text "let condition = " <> condition <> D.text ";" <> D.hardline <>
          D.text "if condition.boolean()? " <> D.block 4 yes <> D.text " else " <> D.block 4 no))
      ShortCircuit op a b -> do
        left <- render names a
        right <- render names b
        let (yes,no) = if op == And then (right,D.text "ls::Value::Bool(false)") else (D.text "ls::Value::Bool(true)",right)
        pure (D.block 4 (D.text "let left = " <> left <> D.text ";" <> D.hardline <>
          D.text "if left.boolean()? " <> D.block 4 yes <> D.text " else " <> D.block 4 no))
      Convert _ target value
        | target == expressionType value -> render names value
        | otherwise -> do
            body <- render names value
            key <- typeKey target
            pure (D.block 4 (D.text "let value = " <> body <> D.text ";" <> D.hardline <>
              call "value.convert" [key,bits] <> D.text "?"))
      Helper Concurrently [value] -> render names value
      Helper builtin args -> do
        values <- mapM (render names) args
        pure (call "ls::helper" [D.text (quoted (builtinName builtin)),vector values] <> D.text "?")
    -- A call: its arguments are written in the call when reading them
    -- cannot borrow the context; otherwise each is made first, left to
    -- right, before the call borrows the context. Its error names what
    -- was called.
    callDoc name label args values
      | all simple args = called (call name [D.text "ctx", vector values])
      | otherwise = D.block 4 (D.joinWith D.hardline
          ([D.hang 4 (D.text ("let " ++ argument ++ " =")) value <> D.text ";" | (argument,value) <- zip arguments values] ++
           [called (call name [D.text "ctx", vector (map D.text arguments)])]))
      where
        arguments = ["argument_" ++ show i | i <- [1 .. length values]]
        called made = call "ls::called" [stringLiteral label, made] <> D.text "?"
        simple a = case expressionNode a of
          Local _ -> True
          Constant (SSymbol _ _) -> False
          Constant _ -> True
          _ -> False
    branch names matched = do
      let binders = caseBinders matched
          named = boundLocals names binders
      body <- render (zip (map binderId binders) named ++ names) (caseBody matched)
      let locals = [unusedAs name body | name <- named]
      (patternText,guard,bindings) <- case (idText (caseConstructor matched), locals) of
        ("Maybe::Absent",[]) -> pure ("ls::Value::Maybe(None)",Nothing,[])
        ("Maybe::Present",[field]) -> pure ("ls::Value::Maybe(Some(payload))",Nothing,["let " ++ field ++ " = *payload;"])
        ("Either::Left",[field]) -> pure ("ls::Value::Left(payload)",Nothing,["let " ++ field ++ " = *payload;"])
        ("Either::Right",[field]) -> pure ("ls::Value::Right(payload)",Nothing,["let " ++ field ++ " = *payload;"])
        ("List::Nil",[]) -> pure ("ls::Value::List(values)",Just (D.text "values.is_empty()"),[])
        ("List::Cons",[first,rest]) -> pure ("ls::Value::List(values)",Just (D.text "!values.is_empty()"),
          ["let mut fields = values.into_iter();","let " ++ first ++ " = fields.next().unwrap();","let " ++ rest ++ " = ls::Value::List(fields.collect());"])
        (tag,_) | any (any ((== caseConstructor matched) . constructorId) . dataConstructors) declarations -> do
          let first = "tag == " ++ quoted tag
              second = "&& fields.len() == " ++ show (length locals)
              condition = D.prefixChoice (first ++ " " ++ second ++ " => {")
                (D.text (first ++ " " ++ second))
                (D.multiline (D.text first <> D.nest 4 (D.hardline <> D.text second)))
          pure ("ls::Value::Data(tag, fields)",Just condition,
            ["let mut fields = fields.into_iter();" | not (null locals)] ++
            ["let " ++ name ++ " = fields.next().unwrap();" | name <- locals])
        _ -> Left ("no Rust match representation for " ++ idText (caseConstructor matched))
      let contents = D.joinWith D.hardline
            (map D.text bindings ++ [D.hang 4 (D.text "let result =") body <> D.text ";",D.text "result"])
          headDoc = case guard of
            Just condition -> D.group (D.text patternText <>
              D.nest 4 (D.softline <> D.text "if " <> condition <> D.text " =>") <> D.softline <> D.text "{")
            Nothing -> D.text (patternText ++ " => {")
      pure (headDoc <> D.nest 4 (D.hardline <> contents) <> D.hardline <> D.text "}")
