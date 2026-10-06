-- Native conversion stays at adapter boundaries; Core expressions keep their
-- canonical representation and schema validation still surrounds every call.
module LawSpec.RustNativeBinding (emitConversions, emitCall, rustReference, nativeTypeFor, nativeTypeWithParameters, convertExpression) where

import Control.Monad (forM, unless)
import Data.List (find, intercalate)
import Data.Maybe (listToMaybe)
import qualified LawSpec.Core as C
import qualified LawSpec.RustExpr as E
import qualified LawSpec.Code.Doc as D
import LawSpec.NativeBinding
import LawSpec.NativeRequest
import LawSpec.RustData (rustDataTypeWithParameters, rustFieldBoxed)

type Environment = ([C.DataDeclaration], [(Int,ResolvedTypeBinding)])
type Parameters = [(C.Id, (String,String,String))]
canonicalType :: Environment -> Parameters -> C.Type -> Either String String
canonicalType (declarations,_) parameters = rustDataTypeWithParameters declarations
  [(identity,canonical) | (identity,(canonical,_,_)) <- parameters]

environment :: [C.DataDeclaration] -> BindingPlan -> Environment
environment declarations plan = (declarations, zip [0..] (resolvedTypes (bindingRepresentations plan)))

rustReference :: NativeRef -> Either String String
rustReference (NativeRef parts) = intercalate "::" <$> mapM part (zip [0::Int ..] parts)
  where
    part (index,name)
      | name `elem` ["crate","self","super"], index == 0 = Right name
      | name `elem` words "Self crate self super" = Left ("invalid Rust native reference segment: " ++ name)
      | name `elem` words "as async await break const continue dyn else enum extern false fn for if impl in let loop match mod move mut pub ref return static struct trait true type unsafe use where while abstract become box do final macro override priv typeof unsized virtual yield try gen union" = Right ("r#" ++ name)
      | otherwise = Right name

findBinding :: Environment -> String -> Maybe (Int,ResolvedTypeBinding)
findBinding (_,bindings) name = find ((== C.Id name) . C.dataId . resolvedDeclaration . snd) bindings

helper :: Bool -> Int -> String
helper outward index = (if outward then "_lawspec_to_native_" else "_lawspec_from_native_") ++ show index

call :: String -> [D.Doc] -> D.Doc
call name args = D.text name <> D.delimitTrailing 4 "(" ")" args

convert :: Environment -> Parameters -> Maybe C.Id -> Bool -> C.Type -> D.Doc -> Either String D.Doc
convert env@(declarations,_) parameters owner outward ty value
  | Just identity <- owner, rustFieldBoxed declarations identity ty = do
      child <- convert env parameters Nothing outward ty (D.text "*" <> value)
      pure (call "Box::new" [child])
  | otherwise = case ty of
      C.TypeVariable identity -> case lookup identity parameters of
        Just (_,_,converter) -> pure (call converter [value])
        Nothing -> Left "unresolved native conversion parameter"
      -- A bound handle holds its native value: a native argument is a clone
      -- of it, and a native result becomes a new handle.
      C.Constructor name [] | Just (_,binding) <- findBinding env name, C.dataHandle (resolvedDeclaration binding) -> do
        native <- rustReference (resolvedNativeType binding)
        pure (if outward
          then D.text "(" <> value <> D.text (").native::<" ++ native ++ ">().unwrap_or_else(|error| panic!(\"{}\", error)).clone()")
          else call "ls::Handle::new" [value])
      C.Constructor name args | Just (index,_) <- findBinding env name -> do
        converters <- forM args $ \case
          C.TypeArgument child -> do
            body <- convert env parameters Nothing outward child (D.text "_item")
            pure (D.text "&|_item| " <> body)
          _ -> Left "indexed native conversion is not supported"
        pure (call (helper outward index) (value:converters))
      C.Constructor "List" [C.TypeArgument child] -> do
        body <- convert env parameters Nothing outward child (D.text "_item")
        pure (D.group (value <> D.nest 4 (D.softbreak <> D.text ".into_iter()" <>
          D.softbreak <> D.text ".map(|_item| " <> body <> D.text ")" <>
          D.softbreak <> D.text ".collect()")))
      C.Constructor "Maybe" [C.TypeArgument child] -> do
        body <- convert env parameters owner outward child (D.text "_item")
        pure (value <> D.text ".map(|_item| " <> body <> D.text ")")
      C.Constructor name [C.TypeArgument child] | name `elem` ["Nullable","Optional"] -> do
        body <- convert env parameters owner outward child (D.text "_item")
        let scope = "ls::" ++ name ++ "::"
            absent = scope ++ if name == "Nullable" then "Null" else "Undefined"
        pure (D.text "match " <> value <> D.text " " <> D.block 4
          (D.text (absent ++ " => " ++ absent ++ ",") <> D.hardline <>
           D.text (scope ++ "Present(_item) => ") <> call (scope ++ "Present") [body] <> D.text ","))
      C.Constructor "Either" [C.TypeArgument left,C.TypeArgument right] -> do
        branches <- forM [("Left",left),("Right",right)] $ \(tag,child) -> do
          body <- convert env parameters owner outward child (D.text "_item")
          pure (D.text ("ls::Either::" ++ tag ++ "(_item) => ") <> call ("ls::Either::" ++ tag) [body] <> D.text ",")
        pure (D.text "match " <> value <> D.text " " <> D.block 4 (D.joinWith D.hardline branches))
      C.Constructor _ arguments -> do
        unless (not (any boundArgument arguments))
          (Left ("native mapping required for applied type: " ++ show ty))
        pure value
      _ -> Left ("unsupported Rust native binding type: " ++ show ty)
  where
    boundArgument (C.TypeArgument (C.TypeVariable _)) = True
    boundArgument (C.TypeArgument (C.Constructor name args)) =
      findBinding env name /= Nothing || any boundArgument args
    boundArgument _ = False

nativeTypeName :: Environment -> Parameters -> C.Type -> Either String String
nativeTypeName env parameters ty = case ty of
  C.TypeVariable identity -> maybe (Left "unresolved native type parameter")
    (\(_,native,_) -> Right native) (lookup identity parameters)
  C.Constructor name args | Just (_,binding) <- findBinding env name -> do
    name' <- rustReference (resolvedNativeType binding)
    applied name' args
  C.Constructor name args | name `elem` ["List","Maybe","Either","Nullable","Optional"] ->
    applied (case name of "List" -> "Vec"; "Maybe" -> "Option"; _ -> "ls::" ++ name) args
  _ -> canonicalType env parameters ty
  where
    applied name args = do
      children <- mapM (\case C.TypeArgument child -> nativeTypeName env parameters child; _ -> Left "indexed native binding") args
      pure (name ++ if null children then "" else "<" ++ intercalate ", " children ++ ">")

emitConversions :: [C.DataDeclaration] -> BindingPlan -> Either String D.Doc
emitConversions declarations plan = do
  let env@(_,allBindings) = environment declarations plan
      -- A handle needs no helpers: conversions wrap or open it in place.
      bindings = [b | b@(_,binding) <- allBindings, not (C.dataHandle (resolvedDeclaration binding))]
  definitions <- forM bindings $ \(index,binding) -> do
    let declaration = resolvedDeclaration binding
        parameters = [(identity,("_T" ++ show i,"_N" ++ show i,"_convert" ++ show i)) |
          (i,identity) <- zip [0::Int ..] (C.dataParameters declaration)]
        ty = C.Constructor (C.idText (C.dataId declaration))
          [C.TypeArgument (C.TypeVariable identity) | (identity,_) <- parameters]
        typeParameters = [name | (_, (canonical,native,_)) <- parameters, name <- [canonical,native]]
        generic = if null typeParameters then "" else "<" ++ intercalate ", " typeParameters ++ ">"
    canonical <- canonicalType env parameters ty
    canonicalName <- canonicalType env [] (C.Constructor (C.idText (C.dataId declaration)) [])
    native <- nativeTypeName env parameters ty
    functions <- forM [True,False] $ \outward -> do
      branches <- forM (resolvedConstructors binding) $ \constructor -> do
        let variant = resolvedConstructor constructor
        tag <- rustReference (NativeRef [C.constructorName variant])
        nativeTag <- rustReference (resolvedNativeConstructor constructor)
        -- A product's canonical form is a struct, so its path has no variant.
        let canonicalTag = if length (C.dataConstructors declaration) == 1 then canonicalName else canonicalName ++ "::" ++ tag
            fields = resolvedFields constructor
        names <- forM (zip [0::Int ..] fields) $ \(i,(field,nativeFieldName)) -> do
          canonicalField <- rustReference (NativeRef [C.binderName field])
          nativeField <- rustReference (NativeRef [nativeFieldName])
          transformed <- convert env parameters (Just (C.dataId declaration)) outward (C.binderType field) (D.text ("_field" ++ show i))
          pure (if outward then canonicalField else nativeField,
                if outward then nativeField else canonicalField, i, transformed)
        let construct isNative name items = D.text name <> if null items
              then if isNative && resolvedConstructorStyle constructor == RecordConstructor then D.text " {}" else mempty
              else D.text " " <> D.block 4 (D.joinWith D.hardline (map (<> D.text ",") items))
            patternDoc = construct (not outward) (if outward then canonicalTag else nativeTag)
              [D.text (source ++ ": _field" ++ show i) | (source,_,i,_) <- names]
            body = construct outward (if outward then nativeTag else canonicalTag)
              [D.text (destination ++ ": ") <> value | (_,destination,_,value) <- names]
        pure (patternDoc <> D.text " => " <> body <> D.text ",")
      let callbacks = [converter ++ ": &dyn Fn(" ++
            (if outward then canonicalParameter else nativeParameter) ++ ") -> " ++
            (if outward then nativeParameter else canonicalParameter) |
            (_, (canonicalParameter,nativeParameter,converter)) <- parameters]
      body <- case resolvedCodec binding of
        Nothing -> pure (D.text "match value " <> D.block 4 (D.joinWith D.hardline branches))
        Just hook -> do
          function <- rustReference (if outward then codecToNative hook else codecFromNative hook)
          let arguments = D.text "value" : [D.text converter | (_,(_,_,converter)) <- parameters]
              context = "native codec " ++ C.idText (C.dataId declaration) ++
                (if outward then " toNative" else " fromNative")
          pure (call function arguments <> D.text ".unwrap_or_else(|error| panic!(\"{}: {}\", " <>
            E.stringLiteral context <> D.text ", error))")
      pure (D.text ("pub fn " ++ helper outward index ++ generic) <>
        D.delimitTrailing 4 "(" ")" (map D.text
          (("value: " ++ (if outward then canonical else native)):callbacks)) <>
        D.text (" -> " ++ (if outward then native else canonical) ++ " ") <>
        D.block 4 body)
    pure (D.joinWith (D.hardline <> D.hardline) functions)
  pure (D.joinWith (D.hardline <> D.hardline) definitions)

emitCall :: [C.DataDeclaration] -> BindingPlan -> [String] -> C.Declaration -> NativeCall -> Either String D.Doc
emitCall declarations plan handlers declaration native = do
  let env = environment declarations plan
      (arguments,result) = C.functionType (C.declarationType declaration)
      context = C.idText (C.declarationId declaration)
      indexed = zip [0::Int ..] arguments
      isUnit ty = ty == C.Constructor "Unit" []
      handleType ty = case ty of
        C.Constructor name [] -> find ((== C.Id name) . C.dataId) declarations >>= \d -> if C.dataHandle d then Just d else Nothing
        _ -> Nothing
      boundHandle d = snd <$> findBinding env (C.idText (C.dataId d))
  -- The native function, and the adapter's arguments it takes.
  (receiving, target, passed) <- case native of
    StaticCall reference -> (\destination -> ([], D.text destination, indexed)) <$> rustReference reference
    -- A constructor takes no Unit arguments.
    ConstructorCall reference -> (\destination -> ([], D.text destination, [a | a@(_,ty) <- indexed, not (isUnit ty)])) <$> rustReference reference
    -- A method is called on the first handle argument, with the rest.
    MethodCall name -> do
      (receiver,handle) <- maybe (Left (context ++ ": a method binding needs a handle argument")) Right
        (listToMaybe [(i,d) | (i,ty) <- indexed, Just d <- [handleType ty]])
      binding <- maybe (Left (context ++ ": a method binding in Rust needs its handle type " ++
        C.dataName handle ++ " bound to a native type")) Right (boundHandle handle)
      receiverType <- rustReference (resolvedNativeType binding)
      method <- rustReference (NativeRef [name])
      -- The handle lends its native value; a method never takes it over.
      pure ([D.group (D.text ("let _native_self: &" ++ receiverType ++ " = value" ++ show receiver ++ ".native()") <>
          D.nest 4 (D.softbreak <> D.text ".unwrap_or_else(|error| panic!(\"{}\", error));"))],
        D.text ("_native_self." ++ method), [a | a@(i,_) <- indexed, i /= receiver])
  values <- mapM (\(i,ty) -> convert env [] Nothing True ty (D.text ("value" ++ show i))) passed
  types <- mapM (nativeTypeName env [] . snd) passed
  let locals = receiving ++ [D.text ("let _native_arg" ++ show i ++ ": " ++ ty ++ " = ") <> value <> D.text ";" |
        ((i,_),(ty,value)) <- zip passed (zip types values)]
      static = case native of StaticCall _ -> True; _ -> False
      -- An async adapter awaits its native future; a constructor is called at once.
      awaited = C.declarationAsync declaration && case native of ConstructorCall _ -> False; _ -> True
      -- An adapter that uses abilities passes its handlers first, as the
      -- generated traits.
      invoked = target <> D.delimitTrailing 4 "(" ")" (map D.text (if static then handlers else []) ++ [D.text ("_native_arg" ++ show i) | (i,_) <- passed]) <>
        (if awaited then D.text ".await" else mempty)
  case () of
    -- A method or constructor's Unit result discards the native return.
    _ | not static && isUnit result ->
          pure (D.joinWith D.hardline (locals ++ [invoked <> D.text ";", D.text "()"]))
    -- A constructor of an unbound handle wraps whatever it returns.
      | ConstructorCall _ <- native, Just d <- handleType result, Nothing <- boundHandle d ->
          pure (D.joinWith D.hardline (locals ++ [D.text "let _native_result = " <> invoked <> D.text ";",
            D.text "ls::Handle::new(_native_result)"]))
      | otherwise -> do
          nativeResult <- nativeTypeName env [] result
          converted <- convert env [] Nothing False result (D.text "_native_result")
          pure (D.joinWith D.hardline (locals ++
            [D.text ("let _native_result: " ++ nativeResult ++ " = ") <> invoked <> D.text ";", converted]))

-- Framework helpers reuse the same source-side codecs; validation remains in
-- the schema runtime on both sides of a native generator or adapter call.
nativeTypeFor :: [C.DataDeclaration] -> BindingPlan -> C.Type -> Either String String
nativeTypeFor declarations plan = nativeTypeWithParameters declarations plan []
nativeTypeWithParameters :: [C.DataDeclaration] -> BindingPlan -> [(C.Id,String)] -> C.Type -> Either String String
nativeTypeWithParameters declarations plan parameters = nativeTypeName (environment declarations plan)
  [(identity,(name,name,"")) | (identity,name) <- parameters]
convertExpression :: [C.DataDeclaration] -> BindingPlan -> Bool -> C.Type -> D.Doc -> Either String D.Doc
convertExpression declarations plan = convert (environment declarations plan) [] Nothing
