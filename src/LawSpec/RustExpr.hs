-- Typed Core expressions shared by Rust properties and framework-independent
-- definitions. Layout is constructed from tokens, never rewritten source text.
module LawSpec.RustExpr
  ( renderExpression, renderExpressionWithContext, scalarLiteral, presenceValue, quoted, stringLiteral, call, vector, reference, typeName
  ) where

import LawSpec.Core
import qualified LawSpec.Core.Schema as Schema
import LawSpec.Scalar
import qualified LawSpec.Code.Doc as D
import Data.Char (ord)
import Data.List (intercalate)
import Numeric (showHex)

quoted :: String -> String
quoted value = '"' : concatMap escape value ++ "\""
  where
    escape '"' = "\\\""
    escape '\\' = "\\\\"
    escape c | ord c < 32 || ord c == 127 = "\\u{" ++ showHex (ord c) "}"
             | otherwise = [c]

-- concat! joins literal tokens at compile time without changing their payload.
-- Split before escaping so neither a Unicode scalar nor an escape is divided.
stringLiteral :: String -> D.Doc
stringLiteral value
  | D.utf8Length (quoted value) <= 64 = D.utf8Text (quoted value)
  | otherwise = call "concat!" (map (D.utf8Text . quoted) (chunks value))
  where
    chunks [] = []
    chunks remaining =
      let count = max 1 (length (takeWhile (\n -> D.utf8Length (quoted (take n remaining)) <= 48) [1..length (take 48 remaining)]))
          (part,rest) = splitAt count remaining
      in part : chunks rest

-- Rustfmt also limits argument and array contents to 60 columns.
delimited :: String -> String -> [D.Doc] -> D.Doc
delimited "vec![" "]" [value] = D.text "vec![" <> D.firstLineWidth 60 value <> D.text "]"
delimited opening closing [value] = D.delimitTrailing 4 opening closing [value]
delimited opening closing values
  | length (intercalate ", " (map (D.render D.Compact) values)) > 60 =
      D.text opening <> D.nest 4 (D.softbreak <>
        D.joinWith D.softline [value <> D.text "," | value <- values]) <>
      D.softbreak <> D.text closing
  | otherwise = D.delimitTrailing 4 opening closing values

call :: String -> [D.Doc] -> D.Doc
call name values = D.text name <> delimited "(" ")" values
vector :: [D.Doc] -> D.Doc
vector = delimited "vec![" "]"

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

typeName :: Type -> String
typeName (Constructor name args) = unwords (name : [typeName t | TypeArgument t <- args])
typeName ty = show ty

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
    nativeInteger n = n >= negate (2 ^ (127 :: Int)) && n < 2 ^ (127 :: Int)
    exact variant constructor (leftName,left) (rightName,right) =
      D.text ("ls::Value::" ++ variant ++ "(") <>
      (if nativeInteger left && nativeInteger right
        then call constructor [big left,big right]
        else D.block 4 (D.hang 4 (D.text ("let " ++ leftName ++ " =")) (big left) <>
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

-- A named payload keeps nested presence states readable and evaluates each
-- payload exactly once, including Symbol fixture lookups.
presenceValue :: String -> Maybe D.Doc -> D.Doc
presenceValue name Nothing = call ("ls::Value::" ++ name) [D.text "None"]
presenceValue name (Just value) = D.text ("ls::Value::" ++ name ++ "(") <>
  D.block 4 (D.hang 4 (D.text "let value =") value <> D.text ";" <> D.hardline <>
    D.text "Some(Box::new(value))") <> D.text ")"

renderExpression :: [DataDeclaration] -> Int -> [(Id,String)] -> [(Id,String)] -> Expr -> Either String D.Doc
renderExpression declarations bits = renderExpressionWithContext declarations
  (D.text (show bits)) (D.text "crate::lawspec_schema::schema()?") reference
  (pure . D.text . quoted . typeName)

-- Schema predicates resolve generic domains using their instantiated arguments.
renderExpressionWithContext :: [DataDeclaration] -> D.Doc -> D.Doc
  -> (Type -> Either String D.Doc) -> (Type -> Either String D.Doc)
  -> [(Id,String)] -> [(Id,String)] -> Expr -> Either String D.Doc
renderExpressionWithContext declarations bits schema typeReference typeKey callees = render
  where
    render names term
      -- An all group's steps run side by side, each on a scoped thread with
      -- its own copy of the context (which shares the workflow runtime).
      | Just (fields,binders,body) <- concurrentGroup term = do
          let suffix = show (length names)
              contexts = ["group_ctx_" ++ suffix ++ "_" ++ show i | i <- [0 .. length fields - 1]]
              handles = ["group_step_" ++ suffix ++ "_" ++ show i | i <- [0 .. length fields - 1]]
              locals = ["group_local_" ++ suffix ++ "_" ++ show i | i <- [0 .. length binders - 1]]
              results = "group_results_" ++ suffix
          steps <- mapM (render names) fields
          inner <- render (zip (map binderId binders) locals ++ names) body
          let spawn (context,handle,step) = D.text ("let " ++ handle ++ " = scope.spawn(|| -> ls::Result<ls::Value> ") <>
                D.block 4 (D.text ("let ctx = &mut " ++ context ++ ";") <> D.hardline <>
                  D.hang 4 (D.text "let value =") step <> D.text ";" <> D.hardline <> D.text "Ok(value)") <> D.text ");"
          pure (D.block 4 (D.joinWith D.hardline
            ([D.text ("let mut " ++ context ++ " = ctx.clone();") | context <- contexts] ++
             [D.text ("let " ++ results ++ " = std::thread::scope(|scope| ") <> D.block 4 (D.joinWith D.hardline
               (map spawn (zip3 contexts handles steps) ++
                [D.text ("vec![" ++ intercalate ", " [handle ++ ".join()" | handle <- handles] ++ "]")])) <> D.text ");",
              D.text ("let mut " ++ results ++ " = ls::joined(" ++ results ++ ")?.into_iter();")] ++
             [D.text ("let " ++ local ++ " = " ++ results ++ ".next().unwrap();") | local <- locals] ++
             [D.hang 4 (D.text "let result =") inner <> D.text ";", D.text "result"])))
    render names term = case expressionNode term of
      AllPayloads value predicates -> do
        argument <- render names value
        ref <- typeReference (expressionType value)
        let member = "payload_member_" ++ show (length names)
        arms <- sequence [do
          body <- render ((binderId binder,member):names) predicate
          pure (D.text (show index ++ " => ") <> D.block 4
            (D.hang 4 (D.text "let accepted =") body <> D.text ";" <>
              D.hardline <> D.text "Ok(accepted)"))
          | (index,(binder,predicate)) <- zip [0::Int ..] predicates]
        let dispatcher = D.text ("|payload_index, " ++ member ++ ", ctx| ") <>
              D.text "match payload_index " <> D.block 4
                (D.joinWith D.hardline (arms ++
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
        let name = "element_" ++ show (length names)
        body <- render ((binderId binder,name):names) predicate
        pure (D.block 4 (D.hang 4 (D.text "let values =") argument <> D.text ";" <>
          D.hardline <> D.text ("ls::all_elements(values, |" ++ name ++ "| ") <> D.block 4
            (D.hang 4 (D.text "let accepted =") body <> D.text ";" <>
              D.hardline <> D.text "Ok(accepted)") <> D.text ")?"))
      Constant scalar -> scalarLiteral scalar
      Local identity -> maybe (Left ("unbound Rust binder: " ++ idText identity))
        (Right . D.text . (++ ".clone()")) (lookup identity names)
      Construct tag fields -> do
        values <- mapM (render names) fields
        let builtin = idText tag `elem` ["List::Nil","List::Cons","Maybe::Nothing","Maybe::Just","Either::Left","Either::Right"]
            construct entries = call (if builtin then "ls::construct" else "ls::construct_data")
              [D.text (quoted (idText tag)),vector entries] <> if builtin then D.text "?" else mempty
            simple field = case expressionNode field of
              Constant _ -> True
              Local _ -> True
              _ -> False
            locals = ["constructor_field_" ++ show i | i <- [0 :: Int .. length fields - 1]]
        -- Preserve evaluation order and keep block-valued fields out of vec!
        -- argument layouts, whose packing rules differ from ordinary calls.
        pure (if all simple fields then construct values else D.block 4
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
        -- Materialize arguments left-to-right before borrowing ctx for the
        -- call. Separate locals keep nested calls out of dense array literals.
        let arguments = ["call_argument_" ++ show i | i <- [0 .. length values - 1]]
            bindings = [D.hang 4 (D.text ("let " ++ name ++ " =")) value <> D.text ";" |
              (name,value) <- zip arguments values]
        pure (D.block 4 (D.joinWith D.hardline (bindings ++
          [D.text "let arguments = " <> vector (map D.text arguments) <> D.text ";"]) <> D.hardline <>
          D.text "let result = " <> call name [D.text "ctx",D.text "arguments"] <> D.text ";" <> D.hardline <>
          D.text "let context = " <> stringLiteral (idText identity) <> D.text ";" <> D.hardline <>
          D.text "result.map_err(|error| format!(\"{context}: {error}\"))?"))
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
    branch names matched = do
      let binders = caseBinders matched
          locals = ["match_local_" ++ show (length names) ++ "_" ++ show i | i <- [0 .. length binders - 1]]
      body <- render (zip (map binderId binders) locals ++ names) (caseBody matched)
      (patternText,guard,bindings) <- case (idText (caseConstructor matched), locals) of
        ("Maybe::Nothing",[]) -> pure ("ls::Value::Maybe(None)",Nothing,[])
        ("Maybe::Just",[field]) -> pure ("ls::Value::Maybe(Some(payload))",Nothing,["let " ++ field ++ " = *payload;"])
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
