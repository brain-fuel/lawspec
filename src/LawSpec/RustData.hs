-- Native declarations and bridges consume resolved Core, never surface syntax.
module LawSpec.RustData (emitRustData, rustDataType, rustDataTypeWithParameters, rustFieldBoxed) where

import LawSpec.DataNames (qualifiedDataName)
import Control.Monad (unless, forM)
import Data.Char (isAscii, isAlphaNum, isLetter, toLower, ord)
import Data.List (nub, intercalate, find)
import Numeric (showHex)
import qualified LawSpec.Core as C
import LawSpec.Core.Types (makeRegistry, checkType)
import LawSpec.Scalar (nativeRepresentation)
import qualified LawSpec.Code.Doc as D

type Names = [(String, String)]

namesFor :: [C.DataDeclaration] -> Either String Names
namesFor declarations = do
  let original = [(C.idText (C.dataId d), C.dataName d) | d <- declarations]
      duplicates name = (> 1) . length . filter ((== map toLower name) . map toLower . snd)
      qualified = [(identity, if duplicates name original then qualifiedDataName identity else name) | (identity,name) <- original]
      names = [(identity, if duplicates name qualified then name ++ "_" ++ concatMap (\c -> showHex (ord c) "_") identity else name) | (identity,name) <- qualified]
  mapM_ (identifier . snd) names
  unless (length names == length (nub (map (map toLower . snd) names))) (Left "conflicting Rust data identities")
  mapM (\(identity,name) -> do native <- identifier name; pure (identity,native)) names

identifier :: String -> Either String String
identifier name = do
  let valid = case name of
        c:cs -> isAscii c && (isLetter c || c == '_') && all (\x -> isAscii x && (isAlphaNum x || x == '_')) cs
        [] -> False
      keywords = words "as async await break const continue dyn else enum extern false fn for if impl in let loop match mod move mut pub ref return static struct trait true type unsafe use where while abstract become box do final macro override priv typeof unsized virtual yield try gen union"
  unless (valid && name `notElem` ["_", "Self", "self", "super", "crate"]) (Left ("invalid Rust data identifier: " ++ name))
  pure (if name `elem` keywords then "r#" ++ name else name)

rustDataType :: [C.DataDeclaration] -> C.Type -> Either String String
rustDataType declarations ty = do
  registry <- makeRegistry declarations
  checkType registry ty
  names <- namesFor declarations
  typeText names [] ty

-- Native boundary converters reuse the canonical representation and recursive
-- indirection choices rather than guessing target field storage independently.
rustDataTypeWithParameters :: [C.DataDeclaration] -> [(C.Id,String)] -> C.Type -> Either String String
rustDataTypeWithParameters declarations parameters ty = do
  names <- namesFor declarations
  typeText names parameters ty

rustFieldBoxed :: [C.DataDeclaration] -> C.Id -> C.Type -> Bool
rustFieldBoxed declarations owner ty = case ty of
  C.Constructor name _ -> name `elem` map (C.idText . C.dataId) declarations &&
    any (reaches []) (inlineNames ty)
  _ -> False
  where
    reaches visited name
      | name == C.idText owner = True
      | name `elem` visited = False
      | otherwise = any (reaches (name:visited))
          [dependency | declaration <- declarations, C.dataId declaration == C.Id name,
            constructor <- C.dataConstructors declaration, field <- C.constructorFields constructor,
            dependency <- inlineNames (C.binderType field)]

typeText :: Names -> [(C.Id,String)] -> C.Type -> Either String String
typeText = typeTextScoped "crate::lawspec_data::"

typeTextScoped :: String -> Names -> [(C.Id,String)] -> C.Type -> Either String String
typeTextScoped scope names parameters ty = case ty of
  C.TypeVariable variable -> maybe (Left "unbound Rust data parameter") Right (lookup variable parameters)
  C.Constructor name arguments -> do
    args <- mapM argument arguments
    case lookup name names of
      Just native -> pure (applied (scope ++ native) args)
      Nothing -> case (name,args) of
        ("List",[_]) -> pure (applied "std::vec::Vec" args)
        ("Maybe",[_]) -> pure (applied "std::option::Option" args)
        ("Either",[_,_]) -> pure (applied "ls::Either" args)
        (n,[_]) | n `elem` ["Nullable", "Optional"] -> pure (applied ("ls::" ++ n) args)
        (_,[]) -> maybe (Left ("no Rust representation for " ++ name)) (Right . qualifyNative) (nativeRepresentation "rust" name)
        _ -> Left ("no Rust data representation for " ++ show ty)
  _ -> Left ("no Rust data representation for " ++ show ty)
  where
    qualifyNative "String" = "std::string::String"
    qualifyNative "Vec<u8>" = "std::vec::Vec<u8>"
    qualifyNative other = other
    argument (C.TypeArgument t) = typeTextScoped scope names parameters t
    argument _ = Left "indexed Rust data is not supported"

applied :: String -> [String] -> String
applied name [] = name
applied name args = name ++ "<" ++ intercalate ", " args ++ ">"

-- Vec provides indirection. Other containers have inline payloads; record the
-- dependencies they expose so mutually recursive declarations are boxed too.
inlineNames :: C.Type -> [String]
inlineNames (C.Constructor "List" _) = []
inlineNames (C.Constructor name arguments) = name : concat [inlineNames t | C.TypeArgument t <- arguments]
inlineNames _ = []

emitRustData :: D.Layout -> [C.DataDeclaration] -> Either String String
emitRustData layout declarations = do
  _ <- makeRegistry declarations
  names <- namesFor declarations
  definitions <- mapM (definition names) declarations
  pure (D.render layout (D.text "// Generated by LawSpec. Do not edit." <> D.hardline <>
    D.text "use crate::lawspec_runtime as ls;" <> D.hardline <> D.hardline <>
    D.joinWith (D.hardline <> D.hardline) definitions <> D.hardline))
  where
    dependencies name = maybe [] (concatMap (concatMap (inlineNames . C.binderType) . C.constructorFields) . C.dataConstructors)
      (find ((== C.Id name) . C.dataId) declarations)
    reaches owner visited name
      | owner == name = True
      | name `elem` visited = False
      | otherwise = any (reaches owner (name:visited)) (dependencies name)
    definition names declaration = do
      name <- maybe (Left "unplanned Rust declaration") Right (lookup (C.idText (C.dataId declaration)) names)
      let parameters = zip (C.dataParameters declaration) [candidate | n <- [0::Int ..], let candidate = "T" ++ show n, candidate `notElem` map snd names]
          parameterNames = map snd parameters
          owner = C.idText (C.dataId declaration)
          variants = C.dataConstructors declaration
          -- Rust requires each generic parameter to occur outside a recursive
          -- cycle. PhantomData records parameters which have no such field.
          independent variable ty = case ty of
            C.TypeVariable v -> v == variable
            C.Constructor n args | not (reaches owner [] n) -> any (\a -> case a of C.TypeArgument t -> independent variable t; _ -> False) args
            _ -> False
          phantom = [n | (v,n) <- parameters, not (any (any (independent v . C.binderType) . C.constructorFields) variants)]
          markerType = "std::marker::PhantomData<(" ++ concatMap (++ ",") phantom ++ ")>"
          generic = applied name parameterNames
          implHead bound = "impl" ++ (if null parameters then "" else "<" ++ intercalate ", " [n ++ ": ls::" ++ bound | n <- parameterNames] ++ ">") ++ " ls::" ++ bound ++ " for " ++ generic ++ " "
          fieldType ty = case ty of
            C.Constructor n _ | n `elem` map fst names && any (reaches owner []) (inlineNames ty) ->
              (\t -> "std::boxed::Box<" ++ t ++ ">") <$> typeTextScoped "" names parameters ty
            C.Constructor n args | n `elem` ["Maybe", "Either", "Nullable", "Optional"] -> do
              children <- forM args $ \a -> case a of C.TypeArgument t -> fieldType t; _ -> Left "indexed Rust field"
              pure (applied (if n == "Maybe" then "std::option::Option" else "ls::" ++ n) children)
            _ -> typeTextScoped "" names parameters ty
      allFieldTypes <- mapM (mapM (fieldType . C.binderType) . C.constructorFields) variants
      let expandedVariants = any (> 35)
            [length (intercalate ", " [C.binderName f ++ ": " ++ t | (f,t) <- zip (C.constructorFields v) ts])
            | (v,ts) <- zip variants allFieldTypes] || not (null phantom)
      rendered <- forM variants $ \variant -> do
        tag <- identifier (C.constructorName variant)
        fields <- forM (C.constructorFields variant) $ \field -> do
          fieldName <- identifier (C.binderName field)
          ty <- fieldType (C.binderType field)
          pure (fieldName,ty)
        unless (length fields == length (nub (map fst fields)) && all ((/= "_lawspec_marker") . fst) fields)
          (Left "conflicting Rust data fields")
        let marker = [("_lawspec_marker",markerType) | not (null phantom)]
            recordFields = fields ++ marker
            patternFields = map fst fields ++ ["_lawspec_marker: _" | not (null phantom)]
            record limit prefix fs = D.text prefix <> (if null fs then mempty else if length (intercalate ", " fs) > limit then D.text " " <> D.block 4 (D.joinWith D.hardline [D.text (f ++ ",") | f <- fs]) else D.text " " <>
              D.group (D.text "{" <> D.nest 4 (D.softline <> D.commaSep (map D.text fs) <> D.whenBroken (D.text ",")) <> D.softline <> D.text "}"))
            variantDoc = if null recordFields then D.text (tag ++ ",") else
              (if expandedVariants then D.text (tag ++ " ") <> D.block 4 (D.joinWith D.hardline [D.text (f ++ ": " ++ t ++ ",") | (f,t) <- recordFields])
              else record 35 tag [f ++ ": " ++ t | (f,t) <- recordFields]) <> D.text ","
            call function arguments = D.text function <>
              (if length (intercalate ", " (map (D.render D.Compact) arguments)) > 60
              then D.text "(" <> D.nest 4 (D.hardline <> D.joinWith D.hardline [a <> D.text "," | a <- arguments]) <> D.hardline <> D.text ")"
              else D.delimitTrailing 4 "(" ")" arguments)
            encode = record 18 ("Self::" ++ tag) patternFields <> D.text " => " <> D.block 4
              (D.text "let fields = " <> D.text "vec!" <> D.delimitTrailing 4 "[" "]"
                [D.text ("ls::IntoValue::into_value(" ++ f ++ ")") | (f,_) <- fields] <> D.text ";" <> D.hardline <>
               call "ls::Value::Data"
                [D.text (show (C.idText (C.constructorId variant)) ++ ".into()"), D.text "fields"])
            decoded = [f ++ ": _lawspec_field" ++ show i | (i,(f,_)) <- zip [0::Int ..] fields] ++ ["_lawspec_marker: std::marker::PhantomData" | not (null phantom)]
            resultRecord = if null phantom then record 18 ("Self::" ++ tag) decoded else
              D.text ("Self::" ++ tag ++ " ") <> D.block 4 (D.joinWith D.hardline [D.text (f ++ ",") | f <- decoded])
            decode = D.text (show (C.idText (C.constructorId variant)) ++ " if fields.len() == " ++ show (length fields) ++ " => ") <>
              (if null fields then D.text "Ok(" <> resultRecord <> D.text ")," else D.block 4 (D.text "let mut _lawspec_fields = fields.into_iter();" <> D.hardline <>
                D.joinWith D.hardline [D.group (D.text ("let _lawspec_field" ++ show i ++ ": " ++ t ++ " =") <>
                  D.nest 4 (D.softline <> D.text "ls::FromValue::from_value(_lawspec_fields.next().unwrap())?;")) | (i,(_,t)) <- zip [0::Int ..] fields] <>
                (if null fields then mempty else D.hardline) <>
                D.text "Ok(" <> resultRecord <> D.text ")"))
        pure (variantDoc,encode,decode)
      let declarationDoc = D.text "#[derive(Clone, Debug)]" <> D.hardline <>
            D.text ((if null variants then "pub struct " else "pub enum ") ++ generic ++ " ") <>
            D.block 4 (if null variants then D.text "_never: std::convert::Infallible," <>
              (if null parameters then mempty else D.hardline <> D.text ("_marker: std::marker::PhantomData<(" ++ concatMap (++ ",") parameterNames ++ ")>,"))
              else D.joinWith D.hardline [a | (a,_,_) <- rendered])
          encodeDoc = D.text (implHead "IntoValue") <> D.block 4
            (D.text "fn into_value(self) -> ls::Value " <> D.block 4
              (if null variants then D.text "match self._never {}" else
                D.text "match self " <> D.block 4 (D.joinWith D.hardline [a | (_,a,_) <- rendered])))
          decodeDoc = D.text (implHead "FromValue") <> D.block 4
            (D.text "fn from_value(value: ls::Value) -> ls::Result<Self> " <> D.block 4
              (D.text "let ls::Value::Data(tag, fields) = value else {" <> D.nest 4
                (D.hardline <> D.text ("return Err(" ++ show ("expected " ++ owner) ++ ".into());")) <> D.hardline <> D.text "};" <> D.hardline <>
                D.text "match tag.as_str() " <> D.block 4 (D.joinWith D.hardline
                  ([a | (_,_,a) <- rendered] ++ [D.text "_ => " <> D.block 4
                    (D.group (D.text "let message =" <> D.nest 4 (D.softline <> D.text (show ("invalid constructor or fields for " ++ owner) ++ ";"))) <>
                    D.hardline <> D.text "Err(message.into())")]))))
      pure (D.joinWith (D.hardline <> D.hardline) [declarationDoc,encodeDoc,decodeDoc])
