-- Scala pieces of a unit's abilities (see LawSpec.AbilityNames), in the
-- object lawspec.abilities.<unit package>.<Unit>: a trait per ability, a
-- class per spec handler and a recording class per ability. An operation
-- that fails with E answers Either[E, R]. Handlers travel in the symbols map
-- generated code passes to every definition; the shared JVM bodies reach a
-- Scala handler through a bridge in LawSpecScalaAdapters (see
-- LawSpec.ScalaDefinitions).
module LawSpec.AbilityEmit.Scala (emit, productionStub, abilitiesObject, abilitiesObjectOf, operationResult) where

import Data.Char (isAlphaNum, toUpper)
import Data.List (intercalate)
import qualified LawSpec.Core as C
import LawSpec.Backend (localName)
import LawSpec.Common (Artifact(..))
import LawSpec.AbilityNames
import qualified LawSpec.ScalaData as Native
import qualified LawSpec.JavaDefinitions as Definitions
import qualified LawSpec.ScalaExpr as E
import qualified LawSpec.Code.Doc as D
import qualified LawSpec.ScalaLayout as L
import LawSpec.ScalaText (scalaText)
import Data.List (sort, nub)
import LawSpec.Typed.Plan (isTypedHandler, isContextual)
import LawSpec.Typed.Jvm (JvmTyped(..), JvmStyle(..), emitJvmTyped)

capitalize :: String -> String
capitalize (c : cs) = toUpper c : cs
capitalize [] = []

split :: Char -> String -> [String]
split c s = case break (== c) s of
  (a, []) -> [a]
  (a, _ : rest) -> a : split c rest

-- A typed JVM type, written in Java, in Scala's syntax.
-- java.lang's names are qualified, since Scala's Long and String differ.
scalaGenerics :: String -> String
scalaGenerics = go ' '
  where
    go _ [] = []
    go previous text@(c : rest)
      | c == '<' = '[' : go c rest
      | c == '>' = ']' : go c rest
      | isWordChar c =
          let (word, after) = span isWordChar text
              qualified = if previous /= '.' && word `elem` javaLang then "java.lang." ++ word else word
          in qualified ++ go (last word) after
      | otherwise = c : go c rest
    isWordChar x = isAlphaNum x || x == '_'
    javaLang = words "String Long Integer Short Byte Boolean Double Float Character Object Number"

-- The generated object holding a unit's abilities, fully qualified.
abilitiesObject :: C.Unit -> String
abilitiesObject = abilitiesObjectOf . C.idText . C.unitId

-- The same, by the unit's name: an imported ability's pieces are its owner's.
abilitiesObjectOf :: String -> String
abilitiesObjectOf unit =
  let parts = split '.' unit
  in intercalate "." ("lawspec" : "abilities" : init parts ++ [concatMap capitalize (split '_' (last parts))])

-- | An operation's native result: Either[E, R] when it fails with E.
operationResult :: [C.DataDeclaration] -> C.Ability -> String -> C.Type -> Either String D.Doc
operationResult datas a op result = do
  value <- Native.scalaDataTypeDoc datas result
  case lookup op (C.abilityFailures a) of
    Just (C.AbilityRef _ [failure]) -> do
      failureType <- Native.scalaDataTypeDoc datas failure
      pure (D.text "scala.util.Either[" <> failureType <> D.text ", " <> value <> D.text "]")
    _ -> pure value

emit :: Bool -> Int -> [C.DataDeclaration] -> [C.Unit] -> Either String [Artifact]
emit minify bits datas units = do
  typed <- emitJvmTyped ScalaStyle datas units
  mapM (unitFile typed) (filter unitAbilityPieces units)
  where
    layout = if minify then D.Compact else L.scalaStyle
    comment indentation text = L.comment (80 - indentation) text
    -- class Name(...) extends A with B, broken before each when it does
    -- not fit, as scalafmt breaks it.
    classHeader opening parents =
      let (name, params) = break (== '(') opening
          parameters = splitParameters (init (drop 1 params))
          flat = name ++ "(" ++ intercalate ", " parameters ++ ")" ++ concat [" " ++ keyword ++ " " ++ p | (keyword, p) <- zip ("extends" : repeat "with") parents]
      in D.bestFit [line flat, L.parameters (line name) (map line parameters) <> line (" extends " ++ head parents) <>
           D.nest 4 (mconcat [D.hardline <> line ("with " ++ p) | p <- tail parents])] <> line " "
    splitParameters s = case breakOn ", " s of
      Just (a, b) -> a : splitParameters b
      Nothing -> [s]
    breakOn needle = go ""
      where
        go acc hay@(c : rest)
          | take (length needle) hay == needle = Just (reverse acc, drop (length needle) hay)
          | otherwise = go (c : acc) rest
        go _ [] = Nothing
    identifiers = words . map (\c -> if isAlphaNum c || c == '_' then c else ' ')
    calls = Definitions.definitionCalls units
    line = D.text
    block = D.block 2
    unitFile typed u = do
      let qualified = split '.' (abilitiesObject u)
          package = intercalate "." (init qualified)
          name = last qualified
      nestedClashes "Scala" name u
      interfaces <- mapM interface (ownAbilities u)
      handlers <- mapM (\h -> if isTypedHandler (jvmTypedPlan typed) h then typedHandler typed u h else specHandler u h) (C.unitHandlers u)
      recordings <- mapM recording (ownAbilities u)
      let pieces = interfaces ++ handlers ++ recordings
          code = D.render D.Compact (D.joinWith D.hardline pieces)
          used = identifiers code
          members = [line "private val Schema = LawSpecDataSchema.create()" | "Schema" `elem` used] ++
            [line ("private val MachineBits = " ++ show bits) | "MachineBits" `elem` used] ++ pieces
          classes = sort (nub [c | c <- ["LawSpecDataCodecs", "LawSpecDataSchema", "LawSpecRuntime", "LawSpecSchema", "LawSpecScala", "LawSpecScalaCodecs"],
            c `elem` used || (c == "LawSpecDataSchema" && "Schema" `elem` used)])
          imports = case classes of
            [] -> mempty
            [one] -> line ("import _root_.lawspec.runtime." ++ one) <> D.hardline <> D.hardline
            _ -> D.group (line "import _root_.lawspec.runtime.{" <> D.nest 2 (D.softbreak <> D.commaSep (map line classes)) <> D.softbreak <> line "}") <> D.hardline <> D.hardline
          source = line "// Generated by LawSpec. Do not edit." <> D.hardline <>
            line ("package " ++ package) <> D.hardline <> D.hardline <> imports <>
            comment 0 ("The abilities of " ++ C.idText (C.unitId u) ++ ": a trait for each, its spec handlers, and a recording of any handler of it.") <>
            line ("object " ++ name ++ " ") <> block (D.joinWith (D.hardline <> D.hardline) members) <> D.hardline
      pure (Artifact ("src/main/scala/" ++ intercalate "/" qualified ++ ".scala") (D.render layout (Native.rootQualifiedDoc source)) "generated" "source")
    signature a op ty = do
      let (args, result) = C.functionType ty
      types <- mapM (Native.scalaDataTypeDoc datas) args
      resultType <- operationResult datas a op result
      pure (L.parameters (line ("def " ++ Native.escaped op)) [line ("value" ++ show i ++ ": ") <> t | (i, t) <- zip [0 :: Int ..] types] <>
        line ": " <> resultType)
    owning answered op = case [a | a <- answered, op `elem` map fst (C.abilityOperations a)] of
      a : _ -> a
      [] -> C.failAbility
    interface a = do
      methods <- mapM (\(op, ty) -> signature a op ty) (C.abilityOperations a)
      pure (comment 2 ("The " ++ C.abilityName a ++ " ability: a handler answers each of its operations.") <>
        line ("trait " ++ interfaceName a ++ " ") <> block (D.joinWith D.hardline methods))
    codec ty = Native.scalaCodecDocIn (E.schemaName, E.bitsName) (line "symbols") datas ty
    -- An operation that fails with E answers Left when the clause raises E.
    failingBody a op statements = case lookup op (C.abilityFailures a) of
      Just failing@(C.AbilityRef _ [failure]) -> do
        failureCodec <- codec failure
        pure [line "try " <> block (D.joinWith D.hardline (init statements ++ [L.call "scala.util.Right" [last statements]])) <>
          line " catch " <> block (line "case failure: LawSpecRuntime.Failure" <> D.nest 2 (D.softline <> line ("if failure.ability == " ++ show (C.abilityKey failing) ++ " =>")) <>
            D.nest 2 (D.hardline <> L.call "scala.util.Left" [L.chain failureCodec [("decode", [line "failure.value"])]]))]
      _ -> pure statements
    specHandler u h = do
      -- A handler of several abilities answers all their operations.
      answered <- mapM (\ref -> maybe (Left ("unknown ability of handler " ++ C.handlerName h)) Right (unitAbility u ref)) (C.handlerAbilities h)
      let ability = case answered of
            first : _ -> first { C.abilityOperations = concatMap C.abilityOperations answered
                               , C.abilityName = intercalate ", " (map C.abilityName answered) }
            [] -> C.failAbility
      initialState <- case C.handlerState h of
        Nothing -> pure (line "null")
        -- A computed start value is its own definition (<handler>Start).
        Just (_, C.Expr _ (C.ExternalCall startDefinition _) _) -> do
          evaluate <- maybe (Left ("unresolved start of " ++ C.handlerName h)) Right (lookup startDefinition calls)
          pure (E.call evaluate [line "symbols", line "LawSpecRuntime.absent(\"Unit\")"])
        Just (_, start) -> E.renderExpression datas bits localName (\_ _ -> Left "a handler's start value calls nothing") start
      let name = specName h
      methods <- mapM (\(op, ty) -> do
        clause <- maybe (Left (C.handlerName h ++ ": no clause for " ++ op)) Right (lookup op (C.handlerClauses h))
        evaluate <- maybe (Left ("unresolved clause " ++ C.idText clause)) Right (lookup clause calls)
        let owner = owning answered op
        s <- signature owner op ty
        let (args, result) = C.functionType ty
        argumentCodecs <- mapM codec args
        resultCodec <- codec result
        let arguments = line "symbols" : [line "state" | Just _ <- [C.handlerState h]] ++
              (if null args && C.handlerState h == Nothing then [line "LawSpecRuntime.absent(\"Unit\")"]
               else [L.chain c [("encode", [line ("value" ++ show i)])] | (i, c) <- zip [0 :: Int ..] argumentCodecs])
            invocation = E.call evaluate arguments
            outcome = case C.handlerState h of
              Nothing -> [L.bind "result" invocation]
              Just _ -> [L.bind "pair" (L.call "LawSpecRuntime.pairFields" [invocation]), line "state = pair.get(1)", line "val result = pair.get(0)"]
            returned
              | result == C.scalarType "Unit" = [line "()"]
              | otherwise = [L.chain resultCodec [("decode", [line "result"])]]
        body <- failingBody owner op (outcome ++ returned)
        pure (line "override " <> s <> line " = " <> block (D.joinWith D.hardline body))) (C.abilityOperations ability)
      pure (comment 2 ("The spec handler " ++ C.handlerName h ++ " for " ++ C.abilityName ability ++ ".") <>
        classHeader ("class " ++ name ++ "(private val symbols: LawSpecScala.Symbols)") [abilitiesObjectOf (ownerName a) ++ "." ++ interfaceName a | a <- answered] <>
        block (D.joinWith (D.hardline <> D.hardline)
          (D.group (line "private var state: LawSpecRuntime.Value =" <> D.nest 2 (D.softline <> initialState)) : methods)))
    -- A typed spec handler keeps its state typed (in the shared JVM typed
    -- code): each operation converts its arguments, runs the typed clause and
    -- keeps the next state, which shares all it did not change with the
    -- state before.
    typedHandler typed u h = do
      answered <- mapM (\ref -> maybe (Left ("unknown ability of handler " ++ C.handlerName h)) Right (unitAbility u ref)) (C.handlerAbilities h)
      let ability = case answered of
            first : _ -> first { C.abilityOperations = concatMap C.abilityOperations answered
                               , C.abilityName = intercalate ", " (map C.abilityName answered) }
            [] -> C.failAbility
      stateType <- traverse (fmap scalaGenerics . jvmTypedType typed . fst) (C.handlerState h)
      let name = specName h
          start = jvmTypedStart typed (C.handlerId h)
      methods <- mapM (\(op, ty) -> do
        clause <- maybe (Left (C.handlerName h ++ ": no clause for " ++ op)) Right (lookup op (C.handlerClauses h))
        function <- maybe (Left ("untyped clause " ++ C.idText clause)) Right (jvmTypedFunction typed clause)
        let owner = owning answered op
        s <- signature owner op ty
        let (args, result) = C.functionType ty
        argumentCodecs <- mapM codec args
        typedCodecs <- mapM (jvmTypedCodec typed) args
        resultCodec <- codec result
        typedResult <- jvmTypedCodec typed result
        -- A value converts directly between its native and typed forms where
        -- it can; otherwise through its codecs and the dynamic Value.
        let direct = jvmTypedNative typed
            argument i aty c t = case direct aty of
              Just (fromNative, _) -> line (fromNative ++ "(value" ++ show i ++ ")")
              Nothing -> L.call (t ++ ".decode") [L.chain c [("encode", [line ("value" ++ show i)])]]
            arguments = [line "symbols" | isContextual (jvmTypedPlan typed) clause] ++ [line "state" | Just _ <- [C.handlerState h]] ++
              (if null args && C.handlerState h == Nothing then [line "lawspec.runtime.LawSpecFast.Unit.UNIT"]
               else [argument i aty c t | (i, (aty, (c, t))) <- zip [0 :: Int ..] (zip args (zip argumentCodecs typedCodecs))])
            invocation = L.call function arguments
            outcome = case C.handlerState h of
              Nothing -> [L.bind "result" invocation]
              Just _ -> [L.bind "pair" invocation, line "state = pair.second", line "val result = pair.first"]
            returned
              | result == C.scalarType "Unit" = [line "()"]
              | Just (_, toNative) <- direct result = [line (toNative ++ "(result)")]
              | otherwise = [L.chain resultCodec [("decode", [line (typedResult ++ ".encode(result)")])]]
        body <- failingBody owner op (outcome ++ returned)
        pure (L.equalsBody (line "override " <> s) (line "synchronized " <> block (D.joinWith D.hardline body)))) (C.abilityOperations ability)
      -- The state, read and replaced in its native types, and typed.
      accessors <- case (C.handlerState h, stateType) of
        (Just (t, _), Just typedType) -> do
          native <- Native.scalaDataTypeDoc datas t
          stateCodec <- codec t
          typedCodec <- jvmTypedCodec typed t
          let (read', write') = case jvmTypedNative typed t of
                Just (fromNative, toNative) -> (line (toNative ++ "(this.state)"), line ("this.state = " ++ fromNative ++ "(state)"))
                Nothing -> ( L.chain stateCodec [("decode", [line (typedCodec ++ ".encode(this.state)")])]
                           , line "this.state = " <> L.call (typedCodec ++ ".decode") [L.chain stateCodec [("encode", [line "state"])]] )
          pure [ comment 4 "The handler's state, in its native types: a snapshot to show or keep." <>
                 L.equalsBody (line "def currentState: " <> native) (line "synchronized " <> block read')
               , comment 4 "Replaces the handler's state: to force it, reset it or restore a snapshot." <>
                 L.parameters (line "def setState") [line "state: " <> native] <> line ": Unit = synchronized " <> block write'
               , comment 4 "The typed state, shared rather than copied." <>
                 L.equalsBody (line ("def typedState: " ++ typedType)) (line "synchronized { state }")
               , comment 4 "Replaces the typed state." <>
                 L.parameters (line "def setTypedState") [line ("state: " ++ typedType)] <> line ": Unit = synchronized " <> block (line "this.state = state") ]
        _ -> pure []
      pure (comment 2 ("The spec handler " ++ C.handlerName h ++ " for " ++ C.abilityName ability ++ ", with its state typed.") <>
        classHeader ("class " ++ name ++ "(private val symbols: LawSpecScala.Symbols)") [abilitiesObjectOf (ownerName a) ++ "." ++ interfaceName a | a <- answered] <>
        block (D.joinWith (D.hardline <> D.hardline)
          ([D.group (line "private var state: " <> scalaText t <> line " =" <> D.nest 2 (D.softline <> line v)) | Just t <- [stateType], Just v <- [start]] ++
           [ comment 4 "The handler on its own, outside any law: the embedding entry point." <>
             line "def this() = this(LawSpecScala.symbols())" ] ++ methods ++ accessors)))
    recording a = do
      let name = recordingName a
      methods <- mapM (\(op, ty) -> do
        s <- signature a op ty
        let (args, _) = C.functionType ty
        argumentCodecs <- mapM codec args
        let logged = E.call "java.util.List.of[LawSpecRuntime.Value]" [L.chain c [("encode", [line ("value" ++ show i)])] | (i, c) <- zip [0 :: Int ..] argumentCodecs]
            forward = L.call ("inner." ++ Native.escaped op) [line ("value" ++ show i) | i <- [0 .. length args - 1]]
        pure (line "override " <> s <> line " = " <> block (D.joinWith D.hardline
          [ L.call "calls.add" [L.call "LawSpecRuntime.RecordedCall" [E.quoted op, logged]]
          , forward ]))) (C.abilityOperations a)
      pure (comment 2 ("Records each call to a " ++ C.abilityName a ++ " handler, then passes it on.") <>
        classHeader ("class " ++ name ++ "(val inner: " ++ interfaceName a ++ ", private val symbols: LawSpecScala.Symbols)") [interfaceName a, "LawSpecRuntime.Recorded"] <>
        block (D.joinWith (D.hardline <> D.hardline)
          ([ D.group (line "val calls: java.util.List[LawSpecRuntime.RecordedCall] =" <> D.nest 2 (D.softline <>
               L.call "java.util.Collections.synchronizedList" [line "java.util.ArrayList[LawSpecRuntime.RecordedCall]()"]))
           , L.equalsBody (line "override def lawSpecCalls(): java.util.List[LawSpecRuntime.RecordedCall]") (line "calls") ] ++
           methods)))

-- The user-owned production handler of each ability, nested in the unit's
-- adapter object: <Unit>.<Ability>Handler() is what the tests use.
productionStub :: [C.DataDeclaration] -> C.Unit -> C.Ability -> Either String D.Doc
productionStub datas u a = do
  methods <- mapM (\(op, ty) -> do
    let (args, result) = C.functionType ty
    types <- mapM (Native.scalaDataTypeDoc datas) args
    resultType <- operationResult datas a op result
    pure (L.equalsBody (L.parameters (D.text ("override def " ++ Native.escaped op))
      [D.text ("value" ++ show i ++ ": ") <> t | (i, t) <- zip [0 :: Int ..] types] <> D.text ": " <> resultType)
      (D.text ("throw NotImplementedError(" ++ show op ++ ")")))) (C.abilityOperations a)
  -- ability A with T: the handler is made with the case's T.
  made <- traverse (Native.scalaDataTypeDoc datas) (C.abilityResource a)
  pure (L.comment 78 ("The native handler of " ++ displayName a ++ ": " ++ intercalate ", " (map fst (C.abilityOperations a)) ++ ".") <>
    D.group (D.text ("class " ++ productionName a) <> maybe mempty (\t -> D.text "(val resource: " <> t <> D.text ")") made <>
      D.nest 4 (D.softline <> D.text ("extends " ++ abilitiesObject u ++ "." ++ interfaceName a))) <> D.text " " <>
    D.block 2 (D.joinWith D.hardline methods))
