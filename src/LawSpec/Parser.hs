-- | The concrete syntax of LawSpec, keywords first with symbols as aliases, so a
-- specification reads as prose to someone who is not a mathematician.
-- ref:DEC-readable-notation
module LawSpec.Parser (parseSource, parseSources, parseSourcesWith, parseSourceCanonical, parseSourcesWithCanonical, parseSourcesWithBuiltins, parseSourcesWithBuiltinsAndSyntax, sourceUnit) where

import LawSpec.Core.Policy (StagePolicy(..), Retry(..), Strategy(..), Jitter(..), Limit(..), Breaker(..), Bulkhead(..), Hedge(..), emptyPolicy)
import LawSpec.Resilience (resilienceName)
import LawSpec.Collections (collectionsUnit, collectionsAlias, boundedArithmeticBlock, canonicalCollectionTypes, canonicalCollectionNames)
import LawSpec.Time (timeUnit, timeAlias, durationSuffixes, durationFactor, durationLimit, usesTime, timeTypes)
import LawSpec.Builtins (virtualClockHandler, seededHandlerName, seededHandler)
import LawSpec.Temporal (Temporal(..), temporalExpr, budgetExpr, budgetStart)
import LawSpec.Flow (desugarFlows, flowTypeName)
import LawSpec.Regex (parseRegex)
import Control.Monad.Trans.Class (lift)
import qualified Data.List.NonEmpty as NE
import LawSpec.Model
import LawSpec.SourceSyntax (SourceSyntax(..), SyntaxNode(..), sourceSyntax)
import LawSpec.Indexed
import LawSpec.Railway (railwayUnit)
import LawSpec.PreludeNames (preludeValueName)
import LawSpec.DomainModel
import LawSpec.StatefulModel (ModelDeclaration(..), ModelCommand(..), elaborateModels, checkSupervisors)
import LawSpec.Scenario (Protocol(..), Scenario(..), Statement(..), Step(..), Argument(..), checkScenarios, toProgram)
import LawSpec.Core.Program (Program(..))
import LawSpec.Core.Machine (Machine(..), Supervisor(..), SupervisionStrategy(..), Lifetime(..), Consistency(..))
import Data.Functor (($>))
import LawSpec.Scalar
import LawSpec.Core.Semantics (scalarEqual)
import Control.Monad.Combinators.Expr
import Control.Monad (void, unless, when, forM_, forM)
import Control.Monad.Reader (Reader, ask, asks, runReader, local)
import Control.Monad.State.Strict (StateT(..), evalStateT, runStateT, get, put, modify')
import qualified Data.Map.Strict as M
import qualified Data.Map.Lazy as Lazy
import qualified Data.Set as S
import Data.Char (isLower, isUpper, isControl, toUpper, isAlphaNum, isSpace)
import Data.List (uncons, intercalate, isInfixOf, nub)
import Data.Void (Void)
import Text.Megaparsec hiding (SourcePos, parse, runParserT, lookAhead)
import qualified Text.Megaparsec as MP
import Text.Megaparsec.Char
import qualified Text.Megaparsec.Char.Lexer as L

data Header = RefinementHeader [Bool] | DataHeader [Bool] | RecordHeader [(String,Type)] | AliasHeader
type RawP = ParsecT Void String (Reader (M.Map String Header))
-- State sits outside Parsec, so a failed alternative cannot retain syntax
-- records from a branch the real grammar rejected. Ordinary parsing uses
-- Nothing and does not build the inventory.
type P = StateT (Maybe [SyntaxNode]) RawP

runParserT :: P a -> FilePath -> String -> Reader (M.Map String Header) (Either (ParseErrorBundle String Void) a)
runParserT parser = MP.runParserT (evalStateT parser Nothing)

lookAhead :: P a -> P a
lookAhead parser = StateT $ \inventory -> do
  (value,_) <- MP.lookAhead (runStateT parser inventory)
  pure (value,inventory)

sourceNode :: String -> (a -> Maybe String) -> P a -> P a
sourceNode kind describe = sourceNodeBy (\value -> (kind,describe value))

sourceNodeBy :: (a -> (String,Maybe String)) -> P a -> P a
sourceNodeBy describe parser = do
  inventory <- get
  case inventory of
    Nothing -> parser
    Just _ -> do
      (value,range) <- withSpan parser
      let (kind,name) = describe value
      modify' (fmap (SyntaxNode kind name range Nothing :))
      pure value
spaceP :: P ()
spaceP = L.space space1 (L.skipLineComment "--") empty
lexeme :: P a -> P a
lexeme = L.lexeme spaceP
symbol :: String -> P String
symbol = L.symbol spaceP
keyword :: String -> P ()
keyword s = lexeme (try (string s *> notFollowedBy (alphaNumChar <|> char '_')))
ident :: P String
ident = lexeme identRaw
-- The same grammar serves legacy migration and strict canonical input. Built-in
-- sources keep their versioned legacy grammar; user sources opt into RC1.
canonicalP :: P Bool
canonicalP = asks (M.member "profile:canonical")
annotationP :: P ()
annotationP = sourceNode "annotation" (const Nothing) $
  try (keyword "of" *> keyword "type") <|> void (symbol "::")
closeP :: String -> P ()
closeP name = sourceNode "closer" (const (Just name)) $ do
  keyword "end"
  canonical <- canonicalP
  when canonical (keyword name)
plainCloseP :: String -> P ()
plainCloseP name = sourceNode "closer" (const (Just name)) (keyword "end")
sectionP :: String -> P a -> P a
sectionP name body = sourceNode "section" (const (Just name)) $ do
  keyword name
  canonical <- canonicalP
  if canonical then void (symbol ":" <* notFollowedBy (char ':')) else keyword "is"
  body <* plainCloseP name

-- Phrase delimiters are kept in the resolved spelling, so namespace dots in
-- the body cannot be mistaken for qualification and names remain lossless.
phraseNameRaw :: P String
phraseNameRaw = do
  try (string "\"|")
  body <- manyTill character (char '|')
  when (null body || isSpace (head body) || isSpace (last body))
    (fail "a phrase name must be nonempty without leading or trailing whitespace")
  pure ("\"|" ++ concatMap escape body ++ "|")
  where
    character = (char '\\' *> (char '|' <|> char '\\'))
      <|> satisfy (\c -> c /= '|' && c /= '\\' && c /= '\n' && c /= '\r')
    escape c | c == '|' || c == '\\' = ['\\', c]
             | otherwise = [c]

-- | A name without the space after it, so a field access can follow it.
identRaw :: P String
identRaw = phraseNameRaw <|> try (do
  x <- (:) <$> letterChar <*> many (alphaNumChar <|> char '_')
  canonical <- canonicalP
  if x `elem` ["unit","law","requires","is","end","definition","description","rationale","example","expect","implies","and","true","false","references","are","Eq","where","refinement","type","match","with"] ||
      (canonical && x `elem` ["if","then","else","in","when","otherwise","must"])
    then fail "reserved identifier" else pure x)

-- A public prelude operation may coincide with a grammatical word (then).
-- Qualification identifies that namespace without reserving more user names.
preludeIdentifierRaw :: P String
preludeIdentifierRaw = try (do
  name <- (:) <$> letterChar <*> many (alphaNumChar <|> char '_')
  unless (preludeValueName name) (fail "not a public prelude operation")
  pure name) <|> identRaw
-- | A name, or alias.name for a name exported by an imported unit. The alias and
-- the dot are adjacent; write f . g with spaces to compose a function named
-- like an alias.
qualifiedName :: P String
qualifiedName = lexeme qualifiedNameRaw
-- | As qualifiedName, without the space after it.
qualifiedNameRaw :: P String
qualifiedNameRaw = try (do
    alias <- (:) <$> letterChar <*> many (alphaNumChar <|> char '_')
    known <- asks (M.member ("alias:" ++ alias))
    unless known (fail "not an import alias")
    void (char '.')
    n <- identRaw
    pure (alias ++ "." ++ n))
  <|> identRaw
-- | The declared name without its import alias.
baseName :: String -> String
baseName name = case break (== '"') name of
  (_, '"' : _) -> '"' : drop 1 (dropWhile (/= '"') name)
  _ -> reverse (takeWhile (/= '.') (reverse name))
-- | Constructors start with an uppercase letter; prelude.Int32 is a conversion.
startsUpper :: String -> Bool
startsUpper name = take 8 name /= "prelude." && maybe False (isUpper . fst) (uncons (baseName name))
lawNameP :: P String
lawNameP = do
  canonical <- canonicalP
  if canonical then ident else quoted
sectionStartP :: P ()
sectionStartP = do
  canonical <- canonicalP
  if canonical then void (symbol ":" <* notFollowedBy (char ':')) else keyword "is"
lawReference :: P String
lawReference = sourceNode "law-reference" Just $ try (do
    alias <- (:) <$> letterChar <*> many (alphaNumChar <|> char '_')
    known <- asks (M.member ("alias:" ++ alias))
    unless known (fail "not an import alias")
    void (char '.')
    n <- quoted
    pure (alias ++ ".`" ++ n ++ "`"))
  <|> quoted
-- Canonical infix calls have no closing backtick. Header scanners must never
-- pair two calls as a legacy quoted law name, even on the same source line.
quotedOrInfixToken :: P ()
quotedOrInfixToken = canonicalP >>= \canonical ->
  if canonical then void namedInfixP else void quoted

quoted :: P String
quoted = sourceNode "quoted-name" Just $ lexeme (char '`' *> some (satisfy (\c -> c /= '`' && not (isControl c))) <* char '`')
str :: P String
str = sourceNode "text" (const Nothing) $ lexeme $ do
  canonical <- canonicalP
  try (char '"' *> when canonical (notFollowedBy (char '|')))
  manyTill L.charLiteral (char '"')
parens :: P a -> P a
parens = between (symbol "(") (symbol ")")
typeP :: P Type
typeP = sourceNode "type-expression" (Just . prettyType) $ do
  a <- typeAtom
  -- A / A' is a flow parameter: the call takes the state at A to A'.
  a' <- option a (do void (symbol "/"); b <- typeAtom; pure (Application flowTypeName [a, b]))
  option a' (Arrow a' <$> (symbol "->" *> typeP))
typeAtom :: P Type
typeAtom = sourceNode "type-atom" (Just . prettyType) $ anonymousRecordTypeP <|> (Named "Unit" <$ try (symbol "(" *> symbol ")")) <|> try (parens $ do
    n <- ident; annotationP; t <- typeP
    p <- optional (keyword "where" *> expr)
    pure (Refined n t p))
  <|> parens typeP
  -- _ leaves a type for the compiler to fill: a workflow's Either _ T asks
  -- for a generated error type.
  <|> (Variable "_" <$ try (lexeme (char '_' <* notFollowedBy (alphaNumChar <|> char '_'))))
  <|> do
    n0 <- sourceNode "type-name" Just qualifiedName
    canonical <- canonicalP
    let n = if canonical then case n0 of
          "Whole" -> "BigUInt"
          "\"|whole number|" -> "BigUInt"
          "Nat" -> "lawspecPositiveNatural"
          "\"|natural number|" -> "lawspecPositiveNatural"
          _ -> n0
        else n0
    when (canonical && n0 `elem` ["Natural","BigUInt","BigInt"])
      (fail "use Integer, Whole or Nat in 1.0-rc.1; migrate legacy numeric names")
    if n == "lawspecPositiveNatural" then pure (Refined "value" (Named "BigUInt") (Just (Binary ">" (Var "value") (Number 0)))) else do
     headers <- asks (M.lookup n)
     case headers of
       Just (RefinementHeader kinds) -> RefinementApp n <$> mapM argument kinds
       Just (RecordHeader _) -> pure (Named n)
       Just AliasHeader -> fail (n ++ " is not a type declaration")
       Just (DataHeader kinds)
         | and kinds -> application n <$> mapM (const typeAtom) kinds
         | otherwise -> RefinementApp (indexedRefinementName n) <$> mapM indexArgument kinds
       Nothing | n == naturalRefinementName -> pure (RefinementApp n [])
               | n `elem` ["Nullable","Optional","List","Maybe",failAbilityName] || (canonical && n `elem` ["Set","SortedSet"]) -> Applied n <$> typeAtom
               | n == "Either" -> Application n <$> sequence [typeAtom, typeAtom]
               | '.' `elem` n -> pure (Named n)
               | otherwise -> pure (if maybe False (isLower . fst) (uncons n) then Variable n else Named n)
  where indexArgument True = TypeArgument <$> typeAtom
        indexArgument False = ValueArgument <$> (parens indexExpr <|> try numeric <|> (Var <$> ident))
        argument True = TypeArgument <$> typeAtom
        argument False = ValueArgument <$> (parens expr <|> try numeric <|> (BoolLit <$> boolP) <|> (StringLit <$> str) <|> (Var <$> ident))
        application n [] = Named n
        application n [a] = Applied n a
        application n args = Application n args
-- Structural type fields retain public labels and lexical bindings separately.
anonymousRecordTypeP :: P Type
anonymousRecordTypeP = do
  canonical <- canonicalP
  unless canonical empty
  try (keyword "record" <* lookAhead (symbol "{"))
  fields <- between (symbol "{") (symbol "}") (many field)
  unless (length fields == length (nub (map recordFieldLabel fields))) (fail "duplicate record field")
  pure (Record fields)
  where
    field = sourceNode "record-type-field" (Just . recordFieldLabel) $ do
      label <- ident
      annotationP
      ty <- typeP
      void (optional (symbol ","))
      pure (RecordField label label ty)

param :: P (String,Type)
param = sourceNode "parameter" (Just . fst) $ parens $ do
  n <- ident; annotationP; t <- typeP
  p <- optional (keyword "where" *> expr)
  pure (n,maybe t (\e -> Refined n t (Just e)) p)
constraintsP :: P [Constraint]
constraintsP = option [] (keyword "requires" *> some (sourceNode "capability" (\(Capability name _) -> Just name) $ do
  n <- choice [name <$ keyword name | name <- ["Eq","Integer","Ordered","Bounded","Keyed"]]
  Capability n <$> typeP))
refinementP :: P Refinement
refinementP = do
  keyword "refinement"; n <- ident; ps <- many param; cs <- constraintsP
  t <- keyword "is" *> typeP <* plainCloseP "refinement"
  pure (Refinement n ps cs t)
dataTypeP :: P DataTypeDeclaration
dataTypeP = either erased id <$> declarationP
  where erased f = DataTypeDeclaration (familyName f) (map fst (familyParameters f))
          (map indexedDeclaration (familyConstructors f)) (familySpan f) Nothing

-- | wrapper Name (a :: Type)* is <type> [where <predicate over value>] end
wrapperP :: P Wrapper
wrapperP = do
  ((name, parameters, base, predicate), range) <- withSpan $ do
    keyword "wrapper"
    name <- ident
    unless (maybe False (isUpper . fst) (uncons name)) (fail "wrapper names must start with an uppercase letter")
    parameters <- many $ sourceNode "type-parameter" (Just . id) $ parens $ do
      parameter <- ident
      unless (maybe False (isLower . fst) (uncons parameter)) (fail "type parameters must start with a lowercase letter")
      annotationP
      sourceNode "type-parameter-kind" (const (Just "Type")) (keyword "Type")
      pure parameter
    keyword "is"
    base <- typeP
    predicate <- optional (keyword "where" *> expr)
    plainCloseP "wrapper"
    pure (name, parameters, base, predicate)
  pure (Wrapper name parameters base predicate range)

-- | workflow name :: Input -> Result is stage+ end. A stage is a step, written
-- `name :: Type` (an adapter it declares) or `then name` / `>>= name` (an
-- existing function); `map f` / `<$> f`; `mapError f` / `<!> f`;
-- `orElse f` / `recover f` / `<|> f`; `fallback f` / `?? f`; `tap f`; or
-- `ensure p else f`.
workflowP :: P Workflow
workflowP = do
  ((name, ty, stages), range) <- withSpan $ do
    keyword "workflow"
    name <- ident
    annotationP
    ty <- typeP
    keyword "is"
    stages <- some (do stage <- stageP; policies <- many policyP; pure (stage, policies))
    plainCloseP "workflow"
    pure (name, ty, stages)
  pure (Workflow name ty (map fst stages) range
    [(index, foldl (flip ($)) (emptyPolicy "") (map fst policies)) | (index, (_, policies)) <- zip [0 ..] stages, not (null policies)]
    [(index, concatMap snd policies) | (index, (_, policies)) <- zip [0 ..] stages, any (not . null . snd) policies])
  where
    -- A stage's policies follow it, each beginning with its keyword. A
    -- policy that can fail may name, after else, the value of a declared
    -- error type its failure becomes.
    policyP = choice [try retryP <|> try timeoutP, try rateLimitP, try breakerP, try bulkheadP, try cacheP, try compensateP, try hedgeP]
    hedgeP = plain $ do
      keyword "hedge"
      d <- durationP
      most <- option 2 (keyword "max" *> count')
      pure (\p -> p { policyHedge = Just (Hedge d most) })
    compensateP = plain (keyword "compensate" *> ((\undo p -> p { policyCompensate = Just undo }) <$> qualifiedName))
    plain p = (\f -> (f, [])) <$> p
    elseP kind = maybe [] (\e -> [(kind, e)]) <$> optional (keyword "else" *> (constant <$> qualifiedName))
    constant name = if startsUpper name then ConstructLit name [] else Var name
    waitP = (Nothing <$ keyword "reject") <|> (keyword "wait" *> (Just <$> optional (keyword "max" *> durationP)))
    rateLimitP = do
      keyword "rateLimit"
      kind <- choice [k <$ keyword k | k <- ["tokenBucket", "leakyBucket", "fixedWindow", "slidingWindow"]]
      n <- count'
      period <- durationP
      wait <- waitP
      failure <- elseP "RateLimited"
      pure (\p -> p { policyLimit = Just (Limit kind n period wait (resilienceName (kind ++ "Start")) (resilienceName (kind ++ "Admit"))) }, failure)
    breakerP = do
      keyword "circuitBreaker"
      failures <- count'
      window <- durationP
      keyword "cooldown"
      cooldown <- durationP
      failure <- elseP "CircuitOpen"
      pure (\p -> p { policyBreaker = Just (Breaker failures window cooldown
        (resilienceName "breakerStart") (resilienceName "breakerAdmit") (resilienceName "breakerRecord")) }, failure)
    bulkheadP = do
      keyword "bulkhead"
      n <- count'
      wait <- waitP
      failure <- elseP "Saturated"
      pure (\p -> p { policyBulkhead = Just (Bulkhead n wait
        (resilienceName "bulkheadStart") (resilienceName "bulkheadAdmit") (resilienceName "bulkheadRelease")) }, failure)
    cacheP = plain (keyword "cache" *> ((\ttl p -> p { policyCache = Just ttl }) <$> durationP))
    retryP = plain $ do
      keyword "retry"
      (strategy, attempts) <- choice
        [ (,) Immediate <$> (keyword "immediate" *> count')
        , (\d n -> (Fixed d, n)) <$> (keyword "fixed" *> durationP) <*> count'
        , (\d s n -> (Linear d s, n)) <$> (keyword "linear" *> durationP) <*> durationP <*> count'
        , (\d f n m -> (Exponential d f m, n)) <$> (keyword "exponential" *> durationP) <*> count' <*> count'
            <*> optional (keyword "max" *> durationP)
        , (\d n -> (Fibonacci d, n)) <$> (keyword "fibonacci" *> durationP) <*> count'
        , (\f n -> (Custom f, maybe 0 id n)) <$> (keyword "custom" *> qualifiedName) <*> optional count' ]
      jitter <- option NoJitter (keyword "jitter" *> choice
        [FullJitter <$ keyword "full", EqualJitter <$ keyword "equal", DecorrelatedJitter <$ keyword "decorrelated"])
      condition <- optional (keyword "when" *> qualifiedName)
      pure (\p -> p { policyRetry = Just (Retry strategy attempts jitter condition) })
    timeoutP = do
      keyword "timeout"
      d <- durationP
      failure <- elseP "TimedOut"
      pure (\p -> p { policyTimeout = Just d }, failure)
    count' = lexeme L.decimal
    durationP = do
      e <- numeric
      case e of
        ConstructLit "Duration" [Number micros] -> pure micros
        _ -> fail "expected a duration, such as 250ms"
    stageP = do
      (stage, stageRange) <- withSpan $ choice
        [ try (DeclaredStep <$> ident <* annotationP <*> typeP)
        , try ((keyword "then" <|> void (symbol ">>=")) *> (DeclaredStep <$> ident <* annotationP <*> typeP))
        , StepStage <$> ((keyword "then" <|> void (symbol ">>=")) *> qualifiedName)
        , MapStage <$> ((keyword "map" <|> void (symbol "<$>")) *> qualifiedName)
        , MapErrorStage <$> ((keyword "mapError" <|> void (symbol "<!>")) *> qualifiedName)
        , OrElseStage <$> ((keyword "orElse" <|> keyword "recover" <|> void (symbol "<|>")) *> qualifiedName)
        , FallbackStage <$> ((keyword "fallback" <|> void (symbol "??")) *> qualifiedName)
        , TapStage <$> (keyword "tap" *> qualifiedName)
        , sourceNode "all" (const Nothing) $ do
            keyword "all"
            accumulate <- option False (True <$ keyword "accumulate")
            steps <- some (choice
              [ try ((\n t -> (n, Just t)) <$> ident <* annotationP <*> typeP)
              , (\n -> (n, Nothing)) <$> ((keyword "then" <|> void (symbol ">>=")) *> qualifiedName) ])
            plainCloseP "all"
            keyword "combine"
            AllStage accumulate steps <$> qualifiedName
        , EnsureStage <$> (keyword "ensure" *> qualifiedName) <*> (keyword "else" *> qualifiedName) ]
      pure (WorkflowStage stage stageRange)

-- | model name :: [shared] S by M is ... end: commands paired with reference
-- definitions over the model state M. Each line is a command, `start`,
-- `abstract` or `invariant`; `~` and `by` both read "modelled by".
-- protocol Name is (send T | receive T | ! T | ? T)* end: what one end of a
-- channel sends and receives, in order. `.` may separate steps.
protocolP :: P Protocol
protocolP = do
  ((name, steps), range) <- withSpan $ do
    keyword "protocol"
    name <- ident
    keyword "is"
    steps <- many (step <* optional (symbol "."))
    plainCloseP "protocol"
    pure (name, steps)
  pure (Protocol name steps range)
  where
    step = (Send <$> ((keyword "send" <|> void (symbol "!")) *> typeAtom))
      <|> (Receive <$> ((keyword "receive" <|> void (symbol "?")) *> typeAtom))

-- | scenario `name` in model is (channel c :: Protocol)* statement* end. A
-- command's arguments are on its own line.
scenarioP :: P Scenario
scenarioP = do
  ((name, model, channels, body), range) <- withSpan $ do
    keyword "scenario"
    name <- quoted
    keyword "in"
    model <- ident
    keyword "is"
    -- channel c :: Protocol, or mailbox m of Type: many senders, one receiver.
    declared <- many $ choice
      [ do ((c, p), at) <- withSpan ((,) <$> (keyword "channel" *> ident) <*> (symbol "::" *> ident))
           pure (Left (c, p, at))
      , do ((m, t), at) <- withSpan ((,) <$> (keyword "mailbox" *> ident) <*> (keyword "of" *> typeP))
           pure (Right (m, t, at)) ]
    body <- statements
    plainCloseP "scenario"
    pure (name, model, declared, body)
  pure (Scenario name model [c | Left c <- channels] body range [m | Right m <- channels])
  where
    statements = many statement
    statement = choice [parallel, sending, receiving, expecting, try binding, calling]
    parallel = sourceNode "par" (const Nothing) $ do
      ((branches), at) <- withSpan $ do
        keyword "par"
        first <- statements
        rest <- many (keyword "with" *> statements)
        plainCloseP "par"
        pure (first : rest)
      pure (Par branches at)
    sending = do
      ((c, v), at) <- withSpan ((,) <$> (keyword "send" *> ident) <*> argument)
      pure (SendTo c v at)
    -- receive c x [or else statements end]: the statements run instead of
    -- the rest of the process when c's other process has failed.
    receiving = do
      ((c, x, handler), at) <- withSpan ((,,) <$> (keyword "receive" *> ident) <*> ident
        <*> optional (sourceNode "recovery" (const Nothing) (try (keyword "or" *> keyword "else") *> statements <* plainCloseP "recovery")))
      pure (ReceiveFrom c x handler at)
    expecting = do
      ((x, v), at) <- withSpan ((,) <$> (keyword "expect" *> ident) <*> (symbol "=" *> constant))
      pure (Expect x v at)
    binding = do
      ((x, (command, args)), at) <- withSpan ((,) <$> (ident <* symbol "<-") <*> invocation)
      pure (Bind x command args at)
    calling = do
      ((command, args), at) <- withSpan invocation
      pure (Call command args at)
    invocation = do
      line <- sourceLine <$> getSourcePos
      command <- ident
      args <- many (try (do
        here <- sourceLine <$> getSourcePos
        unless (here == line) (fail "a command's arguments are on its line")
        argument))
      pure (command, args)
    argument = (Given <$> (char '~' *> ident)) <|> (Constant <$> constant) <|> (Held <$> ident)
    constant = parens expr <|> try numeric <|> (StringLit <$> str) <|> (BoolLit <$> boolP)
      <|> ((\n -> ConstructLit n []) <$> try (ident >>= \n -> upper n >> pure n))

-- | A name that starts with an uppercase letter, as a type's does.
upper :: String -> P ()
upper n = unless (maybe False (isUpper . fst) (uncons n)) (fail "expected a type name")

modelP :: P ModelDeclaration
modelP = do
  ((name, shared, state, model, items), range) <- withSpan $ do
    keyword "model"
    name <- ident
    annotationP
    shared <- option False (True <$ keyword "shared")
    state <- typeP
    behaves <- (False <$ keyword "by") <|> (True <$ (keyword "behaves" *> keyword "like"))
    model <- typeP
    keyword "is"
    items <- many item
    plainCloseP "model"
    pure (name, (shared, behaves), state, model, items)
  let (sharedModel, behavesLike) = shared
  pure (ModelDeclaration name sharedModel state model
    (case [s | Left (Left s) <- items] of s : _ -> Just s; [] -> Nothing)
    [c | Right (Left c) <- items]
    (case [a | Left (Right (Left a)) <- items] of a : _ -> Just a; [] -> Nothing)
    [i | Left (Right (Right i)) <- items] range behavesLike Nothing Nothing
    (case [c | Right (Right c) <- items] of c : _ -> Just c; [] -> Nothing))
  where
    modelledBy = void (symbol "~") <|> keyword "by"
    item = choice
      -- A collection model's start may leave its state out: it is empty.
      [ (\f e -> Left (Left (f, e))) <$> (keyword "start" *> ident) <*> option (Var "") (modelledBy *> value)
      , Left . Right . Left <$> (keyword "abstract" *> qualifiedName)
      , Left . Right . Right <$> (keyword "invariant" *> qualifiedName)
      , (\c r w -> Right (Left (ModelCommand c r w False))) <$> try (ident <* modelledBy) <*> qualifiedName
          <*> optional (keyword "when" *> qualifiedName)
      , (\c op -> Right (Left (ModelCommand c op Nothing True))) <$> try (ident <* keyword "as") <*> ident
      , Right . Right <$> (keyword "consistency" *> choice
          [ Linearizable <$ keyword "linearizable", Sequential <$ keyword "sequential"
          , Causal <$ keyword "causal", Eventual <$ keyword "eventual" ]) ]
    -- A model value: a literal, a name or a parenthesized expression, so it
    -- cannot run into the next line.
    value = parens expr
      <|> (ListLit <$> between (symbol "[") (symbol "]") (expr `sepBy` symbol ","))
      <|> try numeric <|> (StringLit <$> str) <|> (BoolLit <$> boolP)
      <|> ((\n -> if maybe False (isUpper . fst) (uncons n) then ConstructLit n [] else Var n) <$> qualifiedName)

-- | actor name :: State by Model is ... end: a process owning a State that
-- handles one message at a time. `on message by reference [when p]` pairs a
-- handler (an adapter State -> args -> Pair Result State) with its
-- reference; `start f [by value]` makes the state; `restart from f by g`
-- gives a restarted actor's state from its last one (g, the model's). Its handle type is the actor's
-- name, capitalized, then Actor: actor account has an AccountActor.
actorP :: P ModelDeclaration
actorP = do
  ((name, own, model, items), range) <- withSpan $ do
    keyword "actor"
    name <- ident
    annotationP
    own <- typeP
    keyword "by"
    model <- typeP
    keyword "is"
    items <- many item
    plainCloseP "actor"
    pure (name, own, model, items)
  let handle = case name of
        c : cs -> toUpper c : cs ++ "Actor"
        [] -> []
      first xs = case xs of x : _ -> Just x; [] -> Nothing
  pure (ModelDeclaration name True (Named handle) model
    (first [s | Left (Left s) <- items])
    [c | Right (Left c) <- items]
    (first [a | Left (Right (Left a)) <- items])
    [i | Left (Right (Right i)) <- items] range False (Just own)
    (first [r | Right (Right r) <- items]) Nothing)
  where
    modelledBy = void (symbol "~") <|> keyword "by"
    item = choice
      [ (\f e -> Left (Left (f, e))) <$> (keyword "start" *> ident) <*> option (Var "") (modelledBy *> value)
      , Left . Right . Left <$> (keyword "abstract" *> qualifiedName)
      , Left . Right . Right <$> (keyword "invariant" *> qualifiedName)
      , (\f g -> Right (Right (f, g))) <$> (keyword "restart" *> keyword "from" *> qualifiedName) <*> (modelledBy *> qualifiedName)
      , (\c r w -> Right (Left (ModelCommand c r w False))) <$> (keyword "on" *> ident) <*> (modelledBy *> qualifiedName)
          <*> optional (keyword "when" *> qualifiedName) ]
    value = parens expr
      <|> (ListLit <$> between (symbol "[") (symbol "]") (expr `sepBy` symbol ","))
      <|> try numeric <|> (StringLit <$> str) <|> (BoolLit <$> boolP)
      <|> ((\n -> if maybe False (isUpper . fst) (uncons n) then ConstructLit n [] else Var n) <$> qualifiedName)

-- | supervisor name is [strategy] [at most n restarts in d] child... end:
-- children are actors or supervisors, each permanent, transient or
-- temporary. The default strategy is one for one, and the default limit 3
-- restarts in 5s.
supervisorP :: P Supervisor
supervisorP = do
  keyword "supervisor"
  name <- ident
  keyword "is"
  strategy <- option OneForOne $ choice
    [ try (keyword "one" *> keyword "for" *> keyword "one") $> OneForOne
    , try (keyword "one" *> keyword "for" *> keyword "all") $> OneForAll
    , (keyword "rest" *> keyword "for" *> keyword "one") $> RestForOne ]
  (restarts, period) <- option (3, 5000000) $ do
    keyword "at"
    keyword "most"
    n <- lexeme L.decimal
    void (keyword "restarts" <|> keyword "restart")
    keyword "in"
    e <- numeric
    case e of
      ConstructLit "Duration" [Number micros] -> pure (n, micros)
      _ -> fail "expected a duration, such as 5s"
  children <- many ((,) <$> choice [Permanent <$ keyword "permanent", Transient <$ keyword "transient", Temporary <$ keyword "temporary"] <*> ident)
  plainCloseP "supervisor"
  pure (Supervisor name strategy restarts period children)

-- | Declarations with a Natural parameter or an index equation are indexed
-- families; LawSpec.Indexed elaborates them after the unit is parsed.
declarationP :: P (Either IndexedFamily DataTypeDeclaration)
declarationP = canonicalRecordP <|> do
  ((name, parameters, constructors), range) <- withSpan $ do
    keyword "type"
    name <- upperName
    parameters <- many $ sourceNode "type-parameter" (Just . fst) $ parens $ do
      parameter <- ident
      unless (maybe False (isLower . fst) (uncons parameter)) (fail "type parameters must start with a lowercase letter")
      annotationP
      canonical <- canonicalP
      isType <- (True <$ sourceNode "type-parameter-kind" (const (Just "Type")) (keyword "Type")) <|>
        (False <$ sourceNode "type-parameter-kind" (const (Just (if canonical then "Whole" else naturalRefinementName)))
          (keyword (if canonical then "Whole" else naturalRefinementName)))
      pure (parameter, isType)
    keyword "is"
    canonical <- canonicalP
    when canonical (keyword "one" *> keyword "of")
    let typeParameters = [p | (p, True) <- parameters]
        equation = sourceNode "type-equation" (Just . fst) $ do
          lhs <- ident
          void (symbol "=")
          if lhs `elem` typeParameters then (,) lhs . Left <$> typeP else (,) lhs . Right <$> indexExpr
    constructors <- many $ do
      void (optional (symbol "|"))
      ((tag, fields, equations), constructorRange) <- withSpan $ sourceNode "constructor" (\(name,_,_) -> Just name) $ do
        tag <- upperName
        fields <- if canonical then option [] (do
          annotationP
          ty <- typeP
          pure [("value",ty)]) else many $ try $ sourceNode "constructor-field" (Just . fst) $ do
          field <- ident
          unless (maybe False (isLower . fst) (uncons field)) (fail "field names must start with a lowercase letter")
          annotationP
          (,) field <$> typeP
        -- An equation on a Type parameter refines it (a GADT constructor); on
        -- a Natural parameter it states the index.
        equations <- option [] (keyword "where" *> (equation `sepBy1` symbol ","))
        pure (tag, fields, equations)
      let indexEquations = [(n, e) | (n, Right e) <- equations]
          typeEquations = [(n, t) | (n, Left t) <- equations]
      pure (IndexedConstructor (ConstructorDeclaration tag fields constructorRange typeEquations) indexEquations)
    closeP "type"
    pure (name, parameters, constructors)
  pure $ if all snd parameters && all (null . indexedEquations) constructors
    then Right (DataTypeDeclaration name (map fst parameters) (map indexedDeclaration constructors) range Nothing)
    else Left (IndexedFamily name parameters constructors range)
  where
    upperName = do
      name <- ident
      unless (maybe False (isUpper . fst) (uncons name)) (fail "type and constructor names must start with an uppercase letter")
      pure name
-- Named records are nominal single-constructor products; no new execution
-- mechanism is introduced. Record values retain explicit nominal construction.
canonicalRecordP :: P (Either IndexedFamily DataTypeDeclaration)
canonicalRecordP = do
  canonical <- canonicalP
  unless canonical empty
  ((name, parameters, fields), range) <- withSpan $ do
    try (keyword "type" *> lookAhead (ident *> many typeParameter *> keyword "is" *> keyword "a" *> keyword "record"))
    name <- ident
    parameters <- many typeParameter
    keyword "is"; keyword "a"; keyword "record"
    fields <- between (symbol "{") (symbol "}") (many field)
    unless (length (map fst fields) == length (nub (map fst fields))) (fail "duplicate record field")
    closeP "type"
    pure (name, parameters, fields)
  pure (Right (DataTypeDeclaration name parameters [ConstructorDeclaration name fields range []] range Nothing))
  where typeParameter = sourceNode "type-parameter" Just $
          parens (ident <* annotationP <* sourceNode "type-parameter-kind" (const (Just "Type")) (keyword "Type"))
        field = sourceNode "record-type-field" (Just . fst) $ do
          label <- ident
          annotationP
          ty <- typeP
          void (optional (symbol ","))
          pure (label,ty)

-- Ordered selection reuses lazy matches and select. Binding the scrutinee
-- once also scopes it correctly in nested cases.
data SelectionPattern
  = SelectionConstructor String [SelectionPattern]
  | SelectionRecord [(String,SelectionPattern)]
  | SelectionLiteral Expr | SelectionCondition Expr
  | SelectionBinding String | SelectionAny

data SelectionRow = SelectionRow [SelectionPattern] [(String,Expr)] (Maybe Expr) Expr

firstCaseP :: P Expr
firstCaseP = do
  canonical <- canonicalP
  unless canonical empty
  try (keyword "first" *> keyword "matching" *> keyword "case" *> keyword "of")
  value <- expr
  void (symbol ":" <* notFollowedBy (char ':'))
  branches <- some $ do
    keyword "when"
    explicit <- option False (True <$ try (keyword "it" *> keyword "matches"))
    pattern <- selectionPatternP explicit
    let names = selectionBindings pattern
    unless (length names == length (nub names)) (fail "repeated variable binding in pattern")
    guard <- optional (keyword "if" *> expr <* keyword "then")
    void (optional (keyword "then"))
    body <- expr
    pure $ case pattern of
      SelectionCondition condition -> SelectionRow [SelectionAny] []
        (Just (maybe condition (Binary "&&" condition) guard)) body
      _ -> SelectionRow [pattern] [] guard body
  fallback <- optional (keyword "otherwise" *> expr)
  closeP "case"
  let rows = branches ++ maybe [] (\body -> [SelectionRow [SelectionAny] [] Nothing body]) fallback
  pure (MatchExpr value [MatchBranch letTag ["it"] (selectionMatrix 0 [Var "it"] rows)])

selectionBindings :: SelectionPattern -> [String]
selectionBindings pattern = case pattern of
  SelectionBinding name -> [name]
  SelectionConstructor _ fields -> concatMap selectionBindings fields
  SelectionRecord fields -> concatMap (selectionBindings . snd) fields
  _ -> []

-- Ordered pattern-matrix specialization retains constructor branches in typed
-- Core. That preserves its GADT facts and exhaustiveness audit even for nested
-- patterns. A failed guard resumes with the original rows and lexical scope.
selectionMatrix :: Int -> [Expr] -> [SelectionRow] -> Expr
selectionMatrix _ values [] = MatchExpr (case values of value:_ -> value; [] -> Var "it") []
selectionMatrix depth values rows@(SelectionRow patterns aliases guard body : remaining)
  | null refutable =
      let replacements = aliases ++ [(name,value) | (SelectionBinding name,value) <- zip patterns values]
          result = replaceExprVars replacements body
      in maybe result (\condition -> select (replaceExprVars replacements condition) result
          (selectionMatrix (depth + 1) values remaining)) guard
  | otherwise = case selectedPattern of
      SelectionRecord _ ->
        let labels = nub [label | SelectionRow ps _ _ _ <- rows,
              SelectionRecord fs <- [ps !! position], (label,_) <- fs]
            names = freshNames (length labels)
            projections = [Apply (Var (fieldAccessPrefix ++ label)) selected | label <- labels]
            specialize (SelectionRow ps as g b) = case ps !! position of
              SelectionRecord fs -> SelectionRow (replaceAt position SelectionAny ps ++
                [maybe SelectionAny id (lookup label fs) | label <- labels]) as g b
              _ -> SelectionRow (ps ++ replicate (length labels) SelectionAny) as g b
            result = selectionMatrix (depth + 1) (values ++ map Var names) (map specialize rows)
        in foldr (\(name,value) rest -> MatchExpr value [MatchBranch letTag [name] rest]) result (zip names projections)
      SelectionConstructor _ _ ->
        let constructors = nub [(tag,length fields) | SelectionRow ps _ _ _ <- rows,
              SelectionConstructor tag fields <- [ps !! position]]
            specialize tag count (SelectionRow ps as g b) = case ps !! position of
              SelectionConstructor other fields | tag == other -> Just (SelectionRow (splice fields ps) as g b)
              SelectionAny -> Just (SelectionRow (splice (replicate count SelectionAny) ps) as g b)
              SelectionBinding name -> Just (SelectionRow (splice (replicate count SelectionAny) ps) ((name,selected):as) g b)
              _ -> Nothing
            branch (tag,count) = let names = freshNames count
              in MatchBranch tag names (selectionMatrix (depth + 1) (splice (map Var names) values)
                [row | original <- rows, Just row <- [specialize tag count original]])
            defaults = [SelectionRow (removeAt position ps) (case ps !! position of
                SelectionBinding name -> (name,selected):as; _ -> as) g b
              | SelectionRow ps as g b <- rows, case ps !! position of
                  SelectionAny -> True; SelectionBinding _ -> True; _ -> False]
        in MatchExpr selected (map branch constructors ++
            [MatchBranch "_" [] (selectionMatrix (depth + 1) (removeAt position values) defaults) | not (null defaults)])
      SelectionLiteral literal | BoolLit _ <- unlocated literal ->
        let specialize value (SelectionRow ps as g b) = case ps !! position of
              SelectionLiteral other | unlocated other == BoolLit value -> Just (SelectionRow (removeAt position ps) as g b)
              SelectionAny -> Just (SelectionRow (removeAt position ps) as g b)
              SelectionBinding name -> Just (SelectionRow (removeAt position ps) ((name,selected):as) g b)
              _ -> Nothing
            branch value = selectionMatrix (depth + 1) (removeAt position values)
              [row | original <- rows, Just row <- [specialize value original]]
        in select selected (branch True) (branch False)
      SelectionLiteral literal ->
        let yes (SelectionRow ps as g b) = case ps !! position of
              SelectionLiteral other | unlocated literal == unlocated other ->
                SelectionRow (replaceAt position SelectionAny ps) as g b
              -- A different spelling can be equal after contextual typing
              -- (1 and 1.0, or IEEE signed zero). Keep it as a typed comparison
              -- when a preceding guard fails, rather than discarding its row.
              _ -> SelectionRow ps as g b
            no = [row | row@(SelectionRow ps _ _ _) <- rows, case ps !! position of
                SelectionLiteral other -> unlocated literal /= unlocated other; _ -> True]
        in select (Binary "==" selected literal)
            (selectionMatrix (depth + 1) values (map yes rows))
            (selectionMatrix (depth + 1) values no)
      _ -> MatchExpr selected []
  where
    refutable = [i | (i,pattern) <- zip [0..] patterns, case pattern of
      SelectionAny -> False; SelectionBinding _ -> False; _ -> True]
    position = head refutable
    selected = values !! position
    selectedPattern = case [p | SelectionRow ps _ _ _ <- rows, p@(SelectionRecord _) <- [ps !! position]] of
      record:_ -> record
      [] -> patterns !! position
    splice fields xs = take position xs ++ fields ++ drop (position + 1) xs
    freshNames count = ["_lawspecSelection" ++ show depth ++ "x" ++ show i | i <- [0..count - 1]]
    select condition yes no = foldl Apply (Var "prelude.select") [condition,yes,no]
    replaceAt i value xs = take i xs ++ [value] ++ drop (i + 1) xs
    removeAt i xs = take i xs ++ drop (i + 1) xs

selectionPatternP :: Bool -> P SelectionPattern
selectionPatternP explicit = wildcard <|> try record <|> try constructor <|> literal
  <|> try (parens (do
    pattern <- selectionPatternP True
    case pattern of
      SelectionBinding _ | not explicit -> empty
      _ -> pure pattern))
  <|> if explicit then binding else condition
  where
    wildcard = SelectionAny <$ (keyword "#any" <|> void (lexeme (char '_' <* notFollowedBy (alphaNumChar <|> char '_'))))
    constructor = do
      tag <- qualifiedName
      unless (startsUpper tag) empty
      recordHeader <- asks (M.lookup ("record:" ++ tag))
      namedRecord <- case recordHeader of
        Just (RecordHeader _) -> optional (keyword "record" *> recordFields)
        _ -> pure Nothing
      case namedRecord of
        Just fields -> do
          declared <- asks (M.lookup ("record:" ++ tag))
          labels <- case declared of
            Just (RecordHeader fs) -> pure (map fst fs)
            _ -> fail (tag ++ " is not a named record")
          unless (all ((`elem` labels) . fst) fields) (fail "unknown record pattern field")
          pure (SelectionConstructor tag [maybe SelectionAny id (lookup label fields) | label <- labels])
        Nothing -> do
          declared <- asks (M.lookup ("constructor:" ++ tag))
          count <- case declared of
            Just (DataHeader fields) -> pure (length fields)
            _ -> maybe (fail ("unknown constructor in pattern: " ++ tag)) pure
              (lookup tag [("Nothing",0),("Just",1),("Left",1),("Right",1),("Nil",0),("Cons",2)])
          SelectionConstructor tag <$> sequence (replicate count (selectionPatternP True))
    record = do
      try (keyword "record" <* lookAhead (symbol "{"))
      fields <- recordFields
      unless (not (null fields))
        (fail "bare empty record patterns require typed structural product support; use a named record pattern or a wildcard")
      pure (SelectionRecord fields)
    recordFields = do
      fields <- between (symbol "{") (symbol "}") (((,) <$> ident <* symbol "=" <*> selectionPatternP True) `sepBy` symbol ",")
      unless (length (map fst fields) == length (nub (map fst fields))) (fail "duplicate record pattern field")
      pure fields
    literal = SelectionLiteral <$> (try numeric <|> (StringLit <$> str) <|> (BoolLit <$> boolP) <|> scalarP)
    binding = do
      name <- ident
      unless (maybe False (isLower . fst) (uncons name)) empty
      pure (SelectionBinding name)
    condition = SelectionCondition <$> expr

recordValueP :: P Expr
recordValueP = do
  value <- recordConstructionP
  fields <- many (try (char '.' *> identRaw))
  spaceP
  pure (foldl (\record field -> Apply (Var (fieldAccessPrefix ++ field)) record) value fields)

recordConstructionP :: P Expr
recordConstructionP = anonymousRecordValueP <|> do
  canonical <- canonicalP
  unless canonical empty
  (name,labels) <- try $ do
    name <- qualifiedName
    lookAhead (keyword "record")
    declared <- asks (M.lookup ("record:" ++ name))
    case declared of
      Just (RecordHeader fs) -> pure (name,map fst fs)
      _ -> empty
  keyword "record"
  fields <- between (symbol "{") (char '}') (field `sepBy` symbol ",")
  let supplied = map fst fields
  unless (length supplied == length (nub supplied)) (fail "duplicate record value field")
  unless (all (`elem` labels) supplied && all (`elem` supplied) labels)
    (fail "a named record value must supply exactly its declared fields")
  -- Preserve evaluation order with lets before canonical declaration ordering.
  let occupied = concatMap (exprVars . snd) fields
      binders = [head [candidate | suffix <- [0 :: Int ..],
        let candidate="_lawspecRecordField" ++ show i ++ replicate suffix '_',candidate `notElem` occupied]
        | i <- [0 :: Int .. length fields - 1]]
      values = zip supplied (map Var binders)
      body = ConstructLit name [maybe (BoolLit False) id (lookup label values) | label <- labels]
  pure (foldr (\(binder,(_,value)) rest -> MatchExpr value [MatchBranch letTag [binder] rest]) body (zip binders fields))
  where field = (,) <$> ident <* symbol "=" <*> expr

anonymousRecordValueP :: P Expr
anonymousRecordValueP = do
  canonical <- canonicalP
  unless canonical empty
  try (keyword "record" <* lookAhead (symbol "{"))
  fields <- between (symbol "{") (char '}') (((,) <$> ident <* symbol "=" <*> expr) `sepBy` symbol ",")
  unless (length fields == length (nub (map fst fields))) (fail "duplicate record value field")
  pure (RecordLit fields)

-- | Index expressions are natural arithmetic, written only where an index is
-- expected. div, mod and ^ elaborate to the prelude's quot, rem and pow, which
-- agree with them on naturals.
indexExpr :: P Expr
indexExpr = located $ makeExprParser indexAtom
  [ [InfixR (helper "pow" <$ symbol "^")]
  , [InfixL (Binary "*" <$ symbol "*"), InfixL (helper "quot" <$ keyword "div"), InfixL (helper "rem" <$ keyword "mod")]
  , [InfixL (Binary "+" <$ symbol "+"), InfixL (Binary "-" <$ try (symbol "-" <* notFollowedBy (char '>')))]
  ]
  where
    helper name a b = Apply (Apply (Var ("prelude." ++ name)) a) b
    indexAtom = located (parens indexExpr <|> try numeric <|> (Var <$> ident))

-- | `e1; e2` sequences at the lowest precedence, and `~s := e` updates a
-- definition's flow parameter just above it.
expr :: P Expr
expr = do
  canonical <- canonicalP
  first <- if canonical then canonicalBoolExpr else statement
  option first (located (sequenced first <$> (symbol ";" *> expr)))
  where
    -- `a; b` orders two expressions: a is evaluated for its effects, then b
    -- gives the value. A flow statement (~s := e, or a call passing ~s) stays
    -- for LawSpec.Flow, which threads the state through it.
    sequenced first rest
      | flowing first = Binary ";" first rest
      | otherwise = MatchExpr first [MatchBranch letTag ["lawspecIgnored"] rest]
    flowing e = any (`isInfixOf` show e) ["Var \"~", "Binary \":=\""]
    statement = do
      e <- updatedExpr
      e' <- option e (budgetSuffix e)
      option e' (located (Binary ":=" e' <$> (symbol ":=" *> updatedExpr)))

-- | A value, and optionally a copy of it with some fields replaced:
-- `b with logs = l, topics = t`. The type of b must have one constructor;
-- inference (LawSpec.Inference.fieldDesugar) makes the copy a match.
updatedExpr :: P Expr
updatedExpr = do
  e <- operatorExpr
  option e (located (foldl update e <$> (fieldStart *> (field `sepBy1` try (symbol "," <* lookAhead fieldStart')))))
  where
    fieldStart = try (keyword "with" *> lookAhead fieldStart')
    fieldStart' = ident *> symbol "=" *> notFollowedBy (char '=')
    field = do
      name <- ident
      unless (maybe False (isLower . fst) (uncons name)) (fail "a field's name starts with a lowercase letter")
      void (symbol "=")
      value <- operatorExpr
      pure (name, value)
    update record (name, value) = Apply (Apply (Var (fieldUpdatePrefix ++ name)) record) value

operatorExpr :: P Expr
operatorExpr = located $ makeExprParser application (higherOperators ++
  -- Matchers (xs has same items as ys, t starts with "a", ...) bind below
  -- the comparisons and above && (see matcherSuffix). Their operands bind
  -- tighter than the comparisons.
  [ [Postfix (matcherSuffix (located (makeExprParser application (init higherOperators))))]
  , [InfixL (Binary "&&" <$ symbol "&&")]
  , [InfixL (Binary "||" <$ symbol "||")]
  ])
  where
    application = sourceNodeBy applicationSyntax $ do
      -- A matcher word after an argument starts a matcher, so contains in
      -- xs contains x is not an argument; a function named contains is
      -- still called as contains xs x.
      -- takes at most ends the expression a budget applies to.
      first <- notFollowedBy budgetStartP *> applicationAtom
      rest <- many (notFollowedBy matcherWord *> notFollowedBy budgetStartP *> guardBoundary *> logicBoundary *> applicationAtom)
      pure $ case first : rest of
        start:others | ConstructLit name [] <- unlocated start -> ConstructLit name others
        terms -> foldl1 Apply terms
    -- The enclosing operator expression may be a comparison. Retain the
    -- actual operand application before precedence combines it, without
    -- adding a Located node or changing the executable expression's origin.
    applicationSyntax value = case unlocated value of
      ConstructLit name _ -> ("application.constructor",Just name)
      _ -> ("application",Nothing)

-- A branch guard starts after its condition, rather than becoming an argument
-- conditional. Parentheses keep ordinary conditional arguments explicit.
guardBoundary :: P ()
guardBoundary = canonicalP >>= \canonical -> when canonical (notFollowedBy (keyword "if"))

logicBoundary :: P ()
logicBoundary = canonicalP >>= \canonical -> when canonical
  (notFollowedBy (keyword "and" <|> keyword "or" <|> keyword "implies"))

-- At the outer level of a let initializer, `in` closes the binding. A
-- delimited subexpression has its own boundary and may use membership.
-- A nested let's body inherits the enclosing initializer's boundary.
membershipScope :: P a -> P a
membershipScope = local (M.delete "delimiter:let-in")

-- The operator levels above the matchers, from the tightest.
higherOperators :: [[Operator P Expr]]
higherOperators =
  [ [Prefix (Unary "!" <$ try (lexeme (char '!' <* notFollowedBy (char '=')))), Prefix (Unary "-" <$ try (lexeme (char '-' <* notFollowedBy digitChar)))]
  , [InfixR (Compose <$ symbol ".")]
  , [InfixL (Binary "*" <$ symbol "*"), InfixL (Binary "/" <$ symbol "/")]
  -- a ++ b joins two Texts, Bytes or Lists: prelude.append a b.
  , [ InfixL ((\a b -> Apply (Apply (Var "prelude.append") a) b) <$ try (symbol "++"))
    , InfixL (Binary "+" <$ try (symbol "+" <* notFollowedBy (char '+'))), InfixL (Binary "-" <$ symbol "-")]
  -- Railway combinators on Either (LawSpec.Railway), each also written as a
  -- prelude name: >=> composes, <$> <!> <*> map and pair, >>= binds, <|> and
  -- ?? recover, and |> applies.
  , [InfixR (Binary ">=>" <$ operator ">=>")]
  , [InfixL (Binary op <$ operator op) | op <- ["<$>","<!>","<*>"]]
  , [InfixL (Binary ">>=" <$ operator ">>=")]
  , [InfixL (Binary op <$ operator op) | op <- ["<|>","??"]]
  , [InfixL (Binary "|>" <$ operator "|>")]
  , [InfixN namedInfixP]
  , [InfixN (Binary op <$ operator op) | op <- ["<=",">=","==","!=","<",">"]] ++
      [InfixN membership]
  ]
  where
    membership = do
      canonical <- canonicalP
      initializer <- asks (M.member "delimiter:let-in")
      unless (canonical && not initializer) empty
      keyword "in"
      pure (\value collection -> Apply (Apply (Var "prelude.member") value) collection)
    -- An operator never matches the start of a longer one: < is not <$>
    -- or <|>, > is not >>= or >=>, and >= is not >=>.
    operator op = (if op == "==" then sourceNode "operator.value-equality" (const (Just op)) else id)
      (try (symbol op <* notFollowedBy (oneOf (longer op))))
    longer op = case op of
      "<" -> "$!*|=" :: String
      ">" -> ">="
      ">=" -> ">"
      _ -> ""

-- Named application is nonassociative and sits immediately above comparisons.
-- Prefix/infix preserve exactly the same function identity and argument order.
namedInfixP :: P (Expr -> Expr -> Expr)
namedInfixP = do
  canonical <- canonicalP
  unless canonical empty
  void (optional (try (keyword "is" <* lookAhead (char '`'))))
  void (char '`')
  name <- (do
      void (char '|')
      body <- manyTill ((char '\\' *> (char '|' <|> char '\\')) <|>
        satisfy (\c -> c /= '|' && c /= '\\' && c /= '\n' && c /= '\r')) (char '|')
      when (null body || isSpace (head body) || isSpace (last body))
        (fail "an infix phrase name must be nonempty without edge whitespace")
      pure ("\"|" ++ concatMap (\c -> if c == '|' || c == '\\' then ['\\',c] else [c]) body ++ "|"))
    <|> qualifiedNameRaw
  spaceP
  pure (\a b -> Apply (Apply (Var name) a) b)

-- The words that start a matcher after an operand (see matcherSuffix), and
-- of, which ends the tolerance in x is within 0.001 of y.
matcherWord :: P ()
matcherWord = choice (map (try . lookAhead)
  [ keyword "contains", keyword "has" *> keyword "same", keyword "is" *> (keyword "subset" <|> keyword "within")
  , keyword "matches", keyword "starts" *> keyword "with", keyword "ends" *> keyword "with"
  , keyword "fails" *> keyword "with", keyword "of" ])

-- A matcher after its subject, as a function of the subject. Each is a
-- typed prelude predicate (LawSpec.Matchers):
--
--   xs has same items as ys        the same items, as many times, in any order
--   xs contains x                  a List item, or a Text inside a Text
--   xs contains all of ys          every item of ys is in xs
--   xs is subset of ys             every item of xs is in ys
--   x is within 0.001 of y         numbers at most 0.001 apart
--   t matches regex "a+"           the whole text matches (LawSpec.Regex)
--   t matches r                    the same, with r :: Regex
--   t starts with "a", t ends with "z"
--   v matches Shipped _ _          v is built by Shipped (nested patterns
--                                  and literals may stand for _)
--   e fails with Declined _ [message contains "card"]
--                                  e raises a failure that matches
matcherSuffix :: P Expr -> P (Expr -> Expr)
matcherSuffix operand = choice
  [ try (keyword "has" *> keyword "same") *> keyword "items" *> keyword "as" *> (call "sameItems" <$> operand)
  , try (keyword "contains" *> keyword "all") *> keyword "of" *> (call "containsAll" <$> operand)
  , keyword "contains" *> (call "contains" <$> operand)
  , try (keyword "is" *> keyword "subset") *> keyword "of" *> (call "isSubsetOf" <$> operand)
  , try (keyword "is" *> keyword "within") *> (do
      tolerance <- operand
      keyword "of"
      other <- operand
      pure (\x -> foldl Apply (Var "prelude.within") [tolerance, x, other]))
  , try (keyword "starts" *> keyword "with") *> (call "startsWith" <$> operand)
  , try (keyword "ends" *> keyword "with") *> (call "endsWith" <$> operand)
  , try (keyword "fails" *> keyword "with") *> failsWith
  , keyword "matches" *> (regexLiteral <|> (flip patternTest <$> patternP) <|> (call "matchesRegex" <$> operand))
  ]
  where
    call name other subject = Apply (Apply (Var ("prelude." ++ name)) subject) other
    regexLiteral = do
      keyword "regex"
      pattern <- regexText
      pure (\subject -> Apply (Apply (Var "prelude.regexMatches") (StringLit pattern)) subject)
    -- e fails with P: attempt e, and its failure matches P.
    failsWith = do
      pattern <- patternP
      message <- optional (try (keyword "message" *> keyword "contains") *> operand)
      let failure = "lawspecFailure"
          checks = patternTest (Var failure) pattern :
            [Apply (Apply (Var "prelude.messageContains") (Var failure)) m | Just m <- [message]]
      pure (\subject -> MatchExpr (Apply (Var "prelude.attempt") subject)
        [ MatchBranch "Either::Left" [failure] (foldr1 (Binary "&&") checks)
        , MatchBranch "Either::Right" ["lawspecResult"] (BoolLit False) ])

-- A regex literal's text, checked against the portable dialect.
regexText :: P String
regexText = do
  pattern <- str
  case parseRegex pattern of
    Left problem -> fail ("regex \"" ++ pattern ++ "\" is not portable: " ++ problem)
    Right _ -> pure pattern

-- A constructor pattern: a constructor and a pattern for each field, where _
-- matches anything, a literal matches an equal value, and a constructor
-- (in parentheses when it has fields) matches what it builds.
data Pattern = AnyValue | EqualTo Expr | Built String [Pattern]

patternP :: P Pattern
patternP = do
  name <- constructorName
  Built name <$> many field
  where
    constructorName = try $ do
      name <- qualifiedName
      unless (startsUpper name) (fail "expected a constructor")
      pure name
    field = (AnyValue <$ lexeme (try (char '_' <* notFollowedBy (alphaNumChar <|> char '_'))))
      <|> parens patternP
      <|> (EqualTo <$> (try numeric <|> (StringLit <$> str) <|> (BoolLit <$> boolP)))
      <|> ((`Built` []) <$> constructorName)

-- Whether value matches the pattern, as a Bool: a match whose other
-- constructors (the wildcard branch _) give false.
patternTest :: Expr -> Pattern -> Expr
patternTest = go (0 :: Int)
  where
    go depth value pattern = case pattern of
      AnyValue -> BoolLit True
      EqualTo literal -> Binary "==" value literal
      Built name fields ->
        let names = ["lawspecField" ++ show depth ++ "x" ++ show i | i <- [0 .. length fields - 1]]
            checks = [go (depth + 1) (Var n) p | (n, p) <- zip names fields, not (isAny p)]
        in MatchExpr value
          [ MatchBranch name names (if null checks then BoolLit True else foldr1 (Binary "&&") checks)
          , MatchBranch "_" [] (BoolLit False) ]
    isAny AnyValue = True
    isAny _ = False

-- One term of an application: a literal, name, parenthesized expression,
-- match, if, raise or calls of.
applicationAtom :: P Expr
applicationAtom = atom
  where
    atom = located $ (ScalarLit (SAbsent "Unit") <$ try (symbol "(" *> symbol ")")) <|> membershipScope setValue <|> membershipScope firstCaseP <|> membershipScope recordValueP <|> temporalP <|> membershipScope matchP <|> membershipScope ifP <|> raiseP <|> callsP <|> letP <|> membershipScope handleP <|> regexP <|> membershipScope (ListLit <$> between (symbol "[") (symbol "]") (expr `sepBy` symbol ",")) <|> (BoolLit <$> boolP) <|> (StringLit <$> str) <|> try scalarP
      <|> membershipScope parenthesizedFields
      <|> try (Var . ('~' :) <$> (char '~' *> ident))
      <|> try numeric <|> try (do n <- ident; alias <- asks (M.member ("alias:" ++ n)); unless (not alias) (fail "import alias"); void (char '.'); b <- ("min" <$ keyword "min") <|> ("max" <$ keyword "max"); pure (TypeBound b (if maybe False (isLower . fst) (uncons n) then Variable n else Named n))) <|> try valueAtom
    -- if, then and else are keywords inside expressions.
    -- (e).logs reads a field of a parenthesized value, the dot adjacent.
    parenthesizedFields = do
      e <- symbol "(" *> (do e <- expr; option e (Annotate e <$> (annotationP *> typeP))) <* char ')'
      fields <- many (try (char '.' *> fieldName))
      spaceP
      pure (foldl (\value field -> Apply (Var (fieldAccessPrefix ++ field)) value) e fields)
    -- b.logs reads the field logs of b, whose type has one constructor; the
    -- dot is adjacent (f . g with spaces composes).
    valueAtom = do
      name <- valueNameRaw
      fields <- if startsUpper name then pure [] else many (try (char '.' *> fieldName))
      spaceP
      when (name `elem` ["if", "then", "else", "in"]) (fail ("expected a value, not the keyword " ++ name))
      pure (if startsUpper name then ConstructLit name []
        else foldl (\value field -> Apply (Var (fieldAccessPrefix ++ field)) value) (Var name) fields)
    fieldName = do
      name <- identRaw
      unless (maybe False (isLower . fst) (uncons name)) (fail "a field's name starts with a lowercase letter")
      pure name
    valueNameRaw = try (do void (string "prelude"); notFollowedBy (alphaNumChar <|> char '_'); spaceP; void (symbol "."); n <- preludeIdentifierRaw; pure ("prelude." ++ n)) <|> qualifiedNameRaw
    -- let x = e in body: e is evaluated first, then body, with x its value.
    letP = sourceNode "let" (const Nothing) $ do
      try (keyword "let" *> lookAhead (ident *> symbol "=" *> notFollowedBy (char '=')))
      name <- sourceNode "let-binding" Just ident
      unless (maybe False (isLower . fst) (uncons name)) (fail "a let binds a name starting with a lowercase letter")
      void (symbol "=")
      value <- local (M.insert "delimiter:let-in" AliasHeader) expr
      keyword "in"
      body <- expr
      pure (MatchExpr value [MatchBranch letTag [name] body])
    -- handle e with h end: e runs with the spec handler h for h's ability.
    handleP = sourceNode "handle" (const Nothing) $ do
      try (keyword "handle")
      body <- expr
      keyword "with"
      -- seededRandom n, or seeded random n: the seeded handler started at n.
      handler <- (seededHandlerName <$> (try (keyword "seeded" *> keyword "random") *> lexeme L.decimal)) <|> do
        name <- ident
        seed <- optional (lexeme L.decimal)
        case seed of
          Nothing -> pure name
          Just n | reverse (takeWhile (/= '.') (reverse name)) == seededHandler -> pure (seededHandlerName n)
                 | otherwise -> fail "only seededRandom takes a seed"
      plainCloseP "handle"
      pure (Apply (Var ("prelude.handle:" ++ handler)) body)
    -- regex "a+": a Regex, checked at compile time (LawSpec.Regex).
    regexP = do
      try (keyword "regex" *> lookAhead (char '"'))
      pattern <- regexText
      pure (ConstructLit "Regex" [StringLit pattern])
    -- raise e: the Fail ability's operation. It aborts to the nearest
    -- handler of Fail, so its value may have any type.
    raiseP = do
      keyword "raise"
      Apply (Var "prelude.raise") <$> operatorExpr
    -- calls of op [with (a, b)]: in a law using a recording handler, how
    -- many times op was called (with those arguments).
    callsP = do
      try (keyword "calls" *> keyword "of")
      op <- ident
      arguments <- optional (keyword "with" *> membershipScope (parens (expr `sepBy1` symbol ",")))
      pure (foldl Apply (Var "prelude.calls") (Var op : maybe [] id arguments))
    -- if c then a else b: only the branch c selects is evaluated (it is
    -- prelude.select, which elaborates to Core's If).
    setValue = do
      canonical <- canonicalP
      unless canonical empty
      void (symbol "#S")
      values <- between (symbol "{") (symbol "}") (expr `sepBy` symbol ",")
      pure (Apply (Var "prelude.setOf") (ListLit values))
    ifP = sourceNode "if" (const Nothing) $ do
      keyword "if"
      condition <- expr
      keyword "then"
      yes <- expr
      keyword "else"
      no <- expr
      canonical <- canonicalP
      when canonical (closeP "if")
      pure (foldl Apply (Var "prelude.select") [condition, yes, no])
    matchP = sourceNode "case" (const Nothing) $ do
      keyword "match"
      canonical <- canonicalP
      when canonical (fail "use first matching case of ...: in 1.0-rc.1")
      value <- expr
      keyword "with"
      branches <- some $ sourceNode "case-branch" (\(MatchBranch tag _ _) -> Just tag) $ do
        void (symbol "|")
        tag <- sourceNode "pattern-constructor" Just qualifiedName
        unless (startsUpper tag) (fail "expected constructor in match pattern")
        names <- many (sourceNode "pattern-binding" Just ident)
        unless (all (maybe False (isLower . fst) . uncons) names) (fail "pattern binders must start with a lowercase letter")
        void (symbol "->")
        MatchBranch tag names <$> expr
      closeP "case"
      pure (MatchExpr value branches)
    -- An adjacent sign remains part of a numeric argument: f -42. For subtraction use x - 42.
located :: P Expr -> P Expr
located parser = do
  (value,range) <- withSpan parser
  let (kind,name) = expressionSyntax value
  modify' (fmap (SyntaxNode ("expression." ++ kind) name range Nothing :))
  pure (Located range value)

expressionSyntax :: Expr -> (String,Maybe String)
expressionSyntax expression = case expression of
  Located _ inner -> expressionSyntax inner
  Var name -> ("name",Just name)
  Apply _ _ -> ("application",Nothing)
  Compose _ _ -> ("composition",Nothing)
  Number _ -> ("literal",Nothing)
  DecimalNumber _ _ -> ("literal",Nothing)
  StringLit _ -> ("literal",Nothing)
  BoolLit _ -> ("literal",Nothing)
  ScalarLit _ -> ("literal",Nothing)
  ListLit _ -> ("list",Nothing)
  RecordLit _ -> ("record",Nothing)
  ConstructLit name _ -> ("constructor",Just name)
  MatchExpr _ _ -> ("match",Nothing)
  AllElementsExpr _ _ _ -> ("all-elements",Nothing)
  AllPayloadsExpr _ _ -> ("all-payloads",Nothing)
  Binary operator _ _ -> ("binary",Just operator)
  Unary operator _ -> ("unary",Just operator)
  Annotate _ _ -> ("annotation",Nothing)
  TypeBound bound _ -> ("type-bound",Just bound)
withSpan :: P a -> P (a,Span)
withSpan parser = do
  start <- getSourcePos
  value <- parser
  end <- getSourcePos
  let position p = Location (sourceName p) (unPos (sourceLine p)) (unPos (sourceColumn p))
  pure (value,Span (position start) (position end))
numeric :: P Expr
numeric = lexeme (try based <|> decimal)
  where
   based = do
     sign <- option 1 ((-1) <$ char '-' <|> 1 <$ char '+')
     base <- try (string "0x" *> pure 16) <|> try (string "0b" *> pure 2)
     digits <- some (if base == 16 then hexDigitChar else oneOf ['0','1'])
     notFollowedBy alphaNumChar
     let digit c | c <= '9' = fromEnum c - fromEnum '0'
                 | c <= 'F' = fromEnum c - fromEnum 'A' + 10
                 | otherwise = fromEnum c - fromEnum 'a' + 10
     pure (Number (sign * foldl (\n c -> n * base + fromIntegral (digit c)) 0 digits))
   decimal = do
    sign <- option "" ((:[]) <$> oneOf ['-','+'])
    ds <- some digitChar
    fraction <- optional (try (char '.' *> some digitChar))
    powerToken <- optional (try (oneOf ['e','E'] *> L.signed (pure ()) L.decimal))
    let power = maybe 0 id powerToken
    let coefficient = read ((if sign == "+" then "" else sign) ++ ds ++ maybe "" id fraction)
    -- A duration literal: a whole number of units, as in 250ms, is the constant
    -- Duration of that many microseconds (LawSpec.Time).
    unit <- optional (try (choice [constructor <$ (string suffix <* notFollowedBy (alphaNumChar <|> char '_'))
      | (suffix, constructor) <- durationSuffixes]))
    case (unit, sign, fraction, powerToken) of
      (Just constructor, "", Nothing, Nothing)
        | coefficient * durationFactor constructor <= durationLimit -> pure (ConstructLit "Duration" [Number (coefficient * durationFactor constructor)])
        | otherwise -> fail ("a duration is at most " ++ show durationLimit ++ " microseconds")
      (Just _, _, _, _) -> fail "a duration literal is a whole number of units, without a sign"
      (Nothing, _, Nothing, Nothing) -> pure (Number coefficient)
      _ -> pure (DecimalNumber coefficient (power - maybe 0 (fromIntegral . length) fraction))
scalarP :: P Expr
scalarP = ScalarLit <$> choice
  [ SAbsent "Unit" <$ keyword "unitValue", SAbsent "Null" <$ keyword "null", SAbsent "Undefined" <$ keyword "undefined"
  , constructor "rational" (SRational <$> integer <* symbol "," <*> integer)
  , constructor "decimal" (SDecimal <$> integer <* symbol "," <*> integer)
  , constructor "symbol" (SSymbol <$> str <* symbol "," <*> str)
  , choice [constructor n (SSequence t <$> units) | (n,t) <- [("bytes","Bytes"),("codePoints","CodePointText"),("utf16","Utf16Text")]]
  , choice [constructor n (SCharacter t <$> unitInteger) | (n,t) <- [("char","Char"),("codePoint","CodePoint"),("codeUnit16","CodeUnit16")]]
  , choice [constructor n (SFloat t <$> str) | (n,t) <- [("float32Bits","Float32"),("float64Bits","Float64")]]
  , choice [constructor n (do r <- component t; void (symbol ","); i <- component t; pure (SComplex result r i)) | (n,t,result) <- [("complex64","Float32","Complex64"),("complex128","Float64","Complex128")]]
  , choice [constructor n (SPresent t . Just <$> scalarLiteral) | (n,t) <- [("nullable","Nullable"),("optional","Optional")]]
  ]
  where
    constructor n p = try (keyword n *> parens p)
    integer = lexeme (L.signed (pure ()) L.decimal)
    unitInteger = do n <- integer; if n >= 0 && n <= 1114111 then pure (fromInteger n) else fail "code point or unit outside representable range"
    units = between (symbol "[") (symbol "]") (unitInteger `sepBy` symbol ",")
    scalarLiteral = do e <- scalarP <|> numeric <|> (StringLit <$> str) <|> (BoolLit <$> boolP)
                       case e of ScalarLit v -> pure v; Number n -> pure (SInteger "BigInt" n); DecimalNumber c p -> pure (SDecimal c p); StringLit s -> pure (textScalar s); BoolLit b -> pure (SBool b); _ -> fail "concrete scalar required"
    component t = do
      e <- try numeric <|> scalarP
      let value = case e of Number n -> SInteger "BigInt" n; DecimalNumber c p -> SDecimal c p; ScalarLit s -> s; _ -> SAbsent "invalid"
      either fail pure (convertScalar 64 t value)
parenthesizedExpr :: P Expr
parenthesizedExpr = parens (do e <- expr; option e (Annotate e <$> (annotationP *> typeP)))

defP :: P Definition
defP = do
  canonical <- canonicalP
  if canonical then canonicalDefinition else legacyDefinition
legacyDefinition :: P Definition
legacyDefinition = (sourceNode "quantifier.forall" (const Nothing) $ do void (symbol "`for all`"); ps <- some param; void (symbol "."); Forall ps <$> defP)
   <|> do a <- clause
          option a (And a <$> (keyword "and" *> defP))
  where
    clause = (Invoke <$> lawReference <*> many (parenthesizedExpr <|> (BoolLit <$> boolP) <|> (StringLit <$> str) <|> (Number <$> lexeme (L.signed (pure ()) L.decimal)) <|> (Var <$> qualifiedName)))
      <|> try (do
        a <- expr
        (keyword "implies" *> (Implies a <$> defP))
          <|> (symbol "=" *> ((Holds <$> recordedP a) <|> (Equal a <$> expr)))
          <|> pure (Holds a))
      <|> parens defP
-- Universal RC1 syntax lowers to the existing typed obligation pipeline.
-- A quantifier owns its end; a section owns a separate end.
canonicalDefinition :: P Definition
canonicalDefinition = do
  canonical <- canonicalP
  unless canonical empty
  makeExprParser atom
    [ [Prefix prefixes]
    , [InfixL (And <$ keyword "and")]
    , [InfixL ((\a b -> Not (And (Not a) (Not b))) <$ keyword "or")]
    , [InfixR (implication <$ keyword "implies")]
    ]
  where
    -- Comparisons remain expressions in value positions (including function
    -- arguments). At a law boundary the same comparison is an obligation.
    -- Try value parentheses before proposition grouping, so (x + 1) = y
    -- keeps its existing meaning while (there exists ... end) can compose.
    atom = quantified <|> existential <|> given <|> application
      <|> try comparisonDefinition <|> parens defP
    prefixes = do
      modifiers <- some ((Not <$ keyword "not") <|> (id <$ keyword "must"))
      pure (\body -> foldr ($) body modifiers)
    comparisonDefinition = do
      a <- canonicalComparison
      pure (case unlocated a of Binary "==" left right -> Equal left right; _ -> Holds a)
    implication a b = case booleanDefinition a of
      Just guard -> Implies guard b
      Nothing -> Not (And a (Not b))
    booleanDefinition definition = case definition of
      Holds value -> Just value
      Equal a b -> Just (Binary "==" a b)
      Not body -> Unary "!" <$> booleanDefinition body
      And a b -> Binary "&&" <$> booleanDefinition a <*> booleanDefinition b
      Implies guard body -> Binary "||" (Unary "!" guard) <$> booleanDefinition body
      _ -> Nothing
    quantified = sourceNode "quantifier.forall" (const Nothing) $ do
      try (keyword "for" *> keyword "all")
      ps <- some param
      void (symbol "=>")
      body <- defP
      plainCloseP "forall"
      pure (Forall ps body)
    existential = sourceNode "quantifier.exists" (\body -> case body of Not _ -> Just "negative"; _ -> Just "positive") $ do
      try (keyword "there" *> lookAhead (keyword "exists" <|> keyword "must" <|> keyword "does"))
      negative <- (False <$ keyword "exists")
        <|> (keyword "must" *> ((True <$ (keyword "not" *> keyword "exist")) <|> (False <$ keyword "exist")))
        <|> (True <$ (keyword "does" *> keyword "not" *> keyword "exist"))
      ps <- some (optional (try (keyword "a" <|> keyword "an")) *> param)
      keyword "such"; keyword "that"
      body <- defP
      plainCloseP "exists"
      pure ((if negative then Not else id) (Exists ps body))
    given = sourceNode "quantifier.given" (const Nothing) $ do
      keyword "given"
      ps <- some param
      guard <- optional (keyword "when" *> canonicalBoolExpr)
      keyword "then"
      body <- defP
      plainCloseP "given"
      pure (Forall ps (maybe body (\c -> Implies c body) guard))
    -- Applying a requirement is explicit, so a law and a function can have
    -- the same spelling without changing ordinary expression resolution.
    application = do
      try (keyword "apply" *> keyword "law")
      name <- try (do keyword "prelude"; void (char '.'); ("prelude." ++) <$> ident)
        <|> qualifiedName
      arguments <- many (notFollowedBy matcherWord *> guardBoundary *> logicBoundary *> applicationAtom)
      pure (Invoke name arguments)

-- The proposition parser and value parser share type-directed equality: a
-- Boolean equality becomes the same Eq obligation when used as a law body.
canonicalBoolExpr :: P Expr
canonicalBoolExpr = located $ makeExprParser canonicalComparison
  [ [Prefix (Unary "!" <$ keyword "not")]
  , [InfixL (Binary "&&" <$ keyword "and")]
  , [InfixL (Binary "||" <$ keyword "or")]
  , [InfixR ((\a b -> Binary "||" (Unary "!" a) b) <$ keyword "implies")]
  ]

canonicalComparison :: P Expr
canonicalComparison = located $ do
  a <- updatedExpr
  option a (do
    wording <- (True <$ try (keyword "must" *> keyword "be"))
      <|> (False <$ try (keyword "must" *> void (symbol "=")))
      <|> (True <$ keyword "is") <|> (False <$ try (symbol "=" <* notFollowedBy (char '=')))
    membership <- if wording then optional (keyword "in") else pure Nothing
    b <- updatedExpr
    pure (case membership of Just _ -> Apply (Apply (Var "prelude.member") a) b; _ -> Binary "==" a b))

boolP :: P Bool
boolP = (keyword "true" *> pure True) <|> (keyword "false" *> pure False)
constructorLiteral :: P Literal
constructorLiteral = do
  name <- try $ do
    name <- qualifiedName
    unless (startsUpper name) (fail "expected constructor literal")
    pure name
  declared <- asks (M.lookup ("constructor:" ++ name))
  arity <- case declared of
    Just (DataHeader fields) -> pure (length fields)
    _ -> maybe (fail ("unknown literal constructor: " ++ name)) pure
      (lookup name [("Nothing",0),("Just",1),("Left",1),("Right",1),("Nil",0),("Cons",2)])
  ConstructorLiteral name <$> count arity literalP

literalP :: P Literal
literalP = sourceNode "literal" literalName $ setLiteral <|> namedRecordLiteral <|> recordLiteral <|> (ScalarLiteral (SAbsent "Unit") <$ try (symbol "(" *> symbol ")")) <|> constructorLiteral
  <|> (ListLiteral <$> between (symbol "[") (symbol "]") (literalP `sepBy` symbol ","))
  <|> try (do e <- scalarP; case e of ScalarLit v -> pure (ScalarLiteral v); _ -> fail "literal")
  <|> try (parens (do
        e <- numeric <|> scalarP
        annotationP
        t <- typeP
        case (e,t) of
          (Number n,Named name) -> either fail (pure . ScalarLiteral) (convertScalar 64 name (SInteger "BigInt" n))
          (DecimalNumber c p,Named name) -> either fail (pure . ScalarLiteral) (convertScalar 64 name (SDecimal c p))
          (ScalarLit v,Named name) -> either fail (pure . ScalarLiteral) (convertScalar 64 name v)
          _ -> fail "expected concrete annotated literal"))
  <|> parens literalP
  <|> (BoolLiteral <$> boolP) <|> (TextLiteral <$> str)
  <|> numericLiteral
  where
    literalName (ConstructorLiteral name _) = Just name
    literalName _ = Nothing
    setLiteral = do
      canonical <- canonicalP
      unless canonical empty
      void (symbol "#S")
      SetLiteral (collectionsAlias ++ ".setOf") <$> between (symbol "{") (symbol "}") (literalP `sepBy` symbol ",")
    namedRecordLiteral = do
      canonical <- canonicalP
      unless canonical empty
      (name,labels) <- try $ do
        name <- qualifiedName
        lookAhead (keyword "record" *> symbol "{")
        declared <- asks (M.lookup ("record:" ++ name))
        case declared of
          Just (RecordHeader fields) -> pure (name,map fst fields)
          _ -> empty
      keyword "record"
      fields <- literalRecordFields
      unless (all (`elem` labels) (map fst fields) && length fields==length labels)
        (fail "a named record literal must supply exactly its declared fields")
      ConstructorLiteral name <$> mapM (\label -> maybe (fail "missing named record literal field") pure (lookup label fields)) labels
    recordLiteral = do
      canonical <- canonicalP
      unless canonical empty
      try (keyword "record" <* lookAhead (symbol "{"))
      RecordLiteral <$> literalRecordFields
    literalRecordFields = do
      fields <- between (symbol "{") (symbol "}") (((,) <$> ident <* symbol "=" <*> literalP) `sepBy` symbol ",")
      unless (length fields == length (nub (map fst fields))) (fail "duplicate record literal field")
      pure fields
    numericLiteral = do
      e <- numeric
      case e of
        Number n -> pure (IntLiteral n)
        DecimalNumber c p -> pure (DecimalLiteral c p)
        ScalarLit v -> pure (ScalarLiteral v)
        -- A duration literal, such as 250ms.
        ConstructLit name [Number n] -> pure (ConstructorLiteral name [IntLiteral n])
        _ -> fail "literal"

block :: String -> P a -> P a
block = sectionP
lawP :: P Law
lawP = fst <$> lawUsingP

-- law `name` params [requires ...] [using h, recording A, ...] is ... end
lawUsingP :: P (Law, [HandlerUse])
lawUsingP = sourceNode "law" (Just . lawName . fst) $ do
  pos <- getSourcePos
  keyword "law"
  n <- lawNameP
  ps <- many param
  req <- constraintsP
  using <- option [] (keyword "using" *> (handlerUseP `sepBy1` symbol ","))
  resources <- lawResourcesP
  keyword "is"
  canonical <- canonicalP
  (d, desc, why, written, refs, metadata) <- if canonical then canonicalLawBodyP else do
    d <- block "definition" defP
    desc <- option "" (block "description" str)
    why <- option "" (block "rationale" str)
    written <- many ((pure <$> exampleP) <|> tableP)
    refs <- option [] (sourceNode "section" (const (Just "references"))
      (keyword "references" *> keyword "are" *> some (ExternalReference Nothing <$> str) <* plainCloseP "references"))
    pure (d, desc, why, written, refs, emptyLawMetadata)
  plainCloseP "law"
  documented <- descriptionExamples desc
  let tables = length [() | rows <- written, isTable rows]
      isTable rows = case rows of
        Example name _ _ : _ -> "table" `isPrefixOf'` name
        [] -> True
      -- With several tables, each row's name says which table it is in.
      numbered = snd (foldl (\(k, acc) rows -> if isTable rows
          then (k + 1, acc ++ [e { exampleName = (if tables > 1 then "table " ++ show k ++ ", " else "") ++
            drop (length ("table " :: String)) (exampleName e) } | e <- rows])
          else (k, acc ++ rows)) (1 :: Int, []) written)
  pure (Law n ps req d desc why (numbered ++ documented) refs (Location (sourceName pos) (unPos (sourceLine pos)) (unPos (sourceColumn pos))) resources metadata, using)
  where
    isPrefixOf' prefix text = take (length prefix) text == prefix

data LawSection = DefinitionSection Definition | DescriptionSection String
  | RationaleSection String | ExamplesSection [Example] | ReferencesSection [DocumentaryReference SourceReferenceTarget]

canonicalLawBodyP :: P (Definition, String, String, [[Example]], [DocumentaryReference SourceReferenceTarget], LawMetadata)
canonicalLawBodyP = do
  scalars <- many scalarMetadataP
  unless (length (map fst scalars) == length (nub (map fst scalars)))
    (fail "law scalar metadata entries are singletons")
  sections <- many (DefinitionSection <$> block "definition" defP
    <|> DescriptionSection <$> block "description" str
    <|> RationaleSection <$> block "rationale" str
    <|> ExamplesSection . pure <$> exampleP
    <|> ExamplesSection <$> tableP
    <|> ReferencesSection . concat <$> block "references" (many documentaryReferencesP))
  misplaced <- optional (lookAhead (keyword "id" <|> keyword "owner"))
  when (misplaced /= Nothing) (fail "scalar metadata must precede law sections")
  let definitions = [d | DefinitionSection d <- sections]
      descriptions = [d | DescriptionSection d <- sections]
      rationales = [d | RationaleSection d <- sections]
      references = [d | ReferencesSection d <- sections]
      namedReferences = [name | entries <- references, ExternalReference (Just name) _ <- entries]
  unless (length definitions == 1) (fail "a law requires exactly one authoritative definition: section")
  unless (all ((<= 1) . length) [descriptions,rationales]) (fail "description and rationale sections are singletons")
  unless (length references <= 1) (fail "references is a singleton section")
  unless (length namedReferences == length (nub namedReferences)) (fail "named external references must be unique within a law")
  case definitions of
    [definition] -> pure (definition, concat descriptions, concat rationales,
      [es | ExamplesSection es <- sections], concat references,
      LawMetadata (lookup "id" scalars) (lookup "owner" scalars))
    _ -> fail "missing law definition"

-- A documentary group is flattened without constructing a value-level set.
-- Dots inside a phrase stay in that name; dots outside qualify the target.
documentaryReferencesP :: P [DocumentaryReference SourceReferenceTarget]
documentaryReferencesP = group (concat <$> documentaryReferencesP `sepBy` symbol ",")
  <|> do
    keyword "ref"
    make <- (LawReference <$ keyword "law") <|>
      ((\target _ -> FunctionReference target) <$ keyword "function")
    targets <- group (referenceTargetP `sepBy1` symbol ",") <|> ((:[]) <$> referenceTargetP)
    selector <- optional referenceSelectorP
    let entries = [make target selector | target <- targets]
    when (selector /= Nothing && any isFunction entries) (fail "a function reference selects its definition and has no section selector")
    pure entries
  <|> ((:[]) <$> namedExternal)
  <|> ((:[]) . ExternalReference Nothing <$> str)
  where
    group = between (symbol "#S{") (symbol "}")
    isFunction FunctionReference{} = True
    isFunction _ = False
    namedExternal = do
      name <- lexeme phraseNameRaw
      void (symbol ":" <* notFollowedBy (char ':'))
      ExternalReference (Just name) <$> str

referenceTargetP :: P SourceReferenceTarget
referenceTargetP = do
  (parts, range) <- lexeme (withSpan ((:) <$> identRaw <*> many (try (char '.' *> identRaw))))
  pure (ParsedReferenceTarget parts range)

referenceSelectorP :: P ReferenceSelector
referenceSelectorP = optional (symbol ".") *> choice
  [ ReferenceDefinition <$ keyword "definition"
  , ReferenceDescription <$ keyword "description"
  , ReferenceRationale <$ keyword "rationale"
  , do keyword "references"
       option ReferenceReferences (ReferenceNamed <$> (symbol "." *> lexeme phraseNameRaw)) ]

scalarMetadataP :: P (String,String)
scalarMetadataP = sourceNode "metadata" (Just . fst) $ do
  name <- ("id" <$ keyword "id") <|> ("owner" <$ keyword "owner")
  void (symbol ":" <* notFollowedBy (char ':'))
  -- Documentary identifiers need no import or value-name resolution.
  value <- str <|> lexeme (intercalate "." <$> identRaw `sepBy1` char '.')
  pure (name,value)

-- for db :: Database, dir :: TemporaryDirectory: the resources a law takes.
lawResourcesP :: P [(String, Type)]
lawResourcesP = option [] $ do
  keyword "for"
  flip sepBy1 (symbol ",") $ do
    name <- ident
    annotationP
    ty <- typeP
    pure (name, ty)

-- resource T is
--   acquire is e end
--   release x is e end
--   [reset x is e end]
-- end
resourceP :: P ResourceDeclaration
resourceP = do
  ((ty, concurrent, acquire, release, reset), range) <- withSpan $ do
    keyword "resource"
    ty <- typeP
    keyword "is"
    concurrent <- option False (True <$ keyword "concurrent")
    acquire <- sourceNode "resource-clause" (const (Just "acquire"))
      (keyword "acquire" *> keyword "is" *> expr <* plainCloseP "acquire")
    release <- clause "release"
    reset <- optional (clause "reset")
    plainCloseP "resource"
    pure (ty, concurrent, acquire, release, reset)
  pure (ResourceDeclaration ty acquire release reset range concurrent)
  where
    clause word = sourceNode "resource-clause" (const (Just word)) $ do
      keyword word
      name <- ident
      keyword "is"
      body <- expr
      plainCloseP word
      pure (name, body)

-- example `name` is (x = literal)* (expect ...)* end
exampleP :: P Example
exampleP = sourceNode "example" (Just . exampleName) $ do
  keyword "example"; en <- lawNameP; sectionStartP
  bs <- some ((,) <$> ident <* symbol "=" <*> literalP)
  checks <- many expectationP
  plainCloseP "example"; pure (Example en bs checks)

-- table (a, b, expected) is (row ...)+ (expect ...)* end: each row is an
-- example. A column on the right of an expect's = holds expected values;
-- every other column binds the law's input of that name. Rows are named
-- "table row 1: 1, 2, 3" here; lawUsingP drops "table " and numbers tables
-- when a law has several.
tableP :: P [Example]
tableP = sourceNode "table" (const Nothing) $ do
  canonical <- canonicalP
  leading <- if canonical then some tableExpectationP <* keyword "in" else pure []
  keyword "table"
  columns <- parens (sourceNode "table-column" Just ident `sepBy1` symbol ",")
  sectionStartP
  rows <- some $ withSpan $ sourceNode "table-row" (const Nothing) $ do
    keyword "row"
    literalP `sepBy1` symbol ","
  checks <- if canonical then pure leading else many tableExpectationP
  plainCloseP "table"
  let expectedColumns = [c | (_, Just (Right (Right c))) <- checks]
  forM_ expectedColumns $ \c -> unless (c `elem` columns)
    (fail ("the table has no column called " ++ c ++ "; its columns are " ++ intercalate ", " columns))
  forM_ (zip [1 :: Int ..] rows) $ \(i, (values, _)) -> unless (length values == length columns)
    (fail ("row " ++ show i ++ " of the table has " ++ show (length values) ++ " values, but the table has " ++ show (length columns) ++ " columns"))
  pure
    [ Example ("table row " ++ show i ++ ": " ++ intercalate ", " (map prettyLiteral values))
        [(c, v) | (c, v) <- row, canonical || c `notElem` expectedColumns]
        [ case right of
            Nothing -> Expectation (substitute left) (BoolLiteral True)
            Just (Left name) -> Expectation (Apply (Apply (Var "prelude.recorded") (StringLit (name ++ " row " ++ show i))) (substitute left)) (BoolLiteral True)
            Just (Right (Left literal)) -> Expectation (substitute left) literal
            Just (Right (Right c)) -> Expectation (substitute left) (maybe (BoolLiteral True) id (lookup c row))
        | (left, right) <- checks
        , let substitute = replaceExprVars [(c, literalExpr v) | (c, v) <- row, c `elem` expectedColumns] ]
    | (i, (values, _)) <- zip [1 :: Int ..] rows, let row = zip columns values ]

tableExpectationP :: P (Expr, Maybe (Either String (Either Literal String)))
tableExpectationP = sourceNode "table-expectation" (const Nothing) $ do
  keyword "expect"
  canonical <- canonicalP
  left <- if canonical then updatedExpr else expr
  right <- optional (symbol "=" *> ((Left <$> (keyword "recorded" *> str)) <|> (Right . Left <$> try (lookAhead (keyword "record" *> symbol "{") *> literalP)) <|> (Right . Right <$> try ident) <|> (Right . Left <$> literalP)))
  pure (left,right)

-- Examples written in a description, in fences:
--
--   ```example [`name`]
--   x = 1
--   expect f x = 2
--   ```
--
-- Each is an example of the law, named after the description.
descriptionExamples :: String -> P [Example]
descriptionExamples description = do
  env <- ask
  forM (zip [1 :: Int ..] (fences (lines description))) $ \(k, (info, body)) -> do
    let name = case parse' (spaceP *> optional quoted <* eof) info of
          Right (Just given) -> Right ("description: " ++ given)
          Right Nothing -> Right ("description example " ++ show k)
          Left problem -> Left problem
        parse' p text = either (Left . errorBundlePretty) Right (runReader (runParserT p "description" text) env)
        example' en = do
          spaceP
          bs <- many (try ((,) <$> ident <* symbol "=" <*> literalP))
          checks <- many expectationP
          eof
          pure (Example en bs checks)
    case name >>= \en -> parse' (example' en) (unlines body) of
      Right e -> pure e
      Left problem -> fail ("the description's example " ++ show k ++ " does not parse: " ++ problem)
  where
    fences ls = case break (isOpening . trim) ls of
      (_, opening : rest) ->
        let (body, after) = break ((== "```") . trim) rest
        in (drop (length ("```example" :: String)) (trim opening), body) : fences (drop 1 after)
      _ -> []
    isOpening line = take 10 line == "```example" && take 1 (drop 10 line) `elem` ["", " "]
    trim = reverse . dropWhile (== ' ') . reverse . dropWhile (== ' ')


-- expect e = literal; expect e = recorded "name"; or expect e, a Bool,
-- such as expect pay 5 fails with Refused.
expectationP :: P Expectation
expectationP = sourceNode "expectation" (const Nothing) $ do
  keyword "expect"
  canonical <- canonicalP
  actual' <- if canonical then updatedExpr else expr
  option (Expectation actual' (BoolLiteral True)) $ do
    void (symbol "=")
    ((`Expectation` BoolLiteral True) <$> recordedP actual') <|> (Expectation actual' <$> literalP)

-- recorded "name": the value stored under recorded/<unit>/<name>, compared
-- by its portable rendering when the law runs; a Bool, prelude.recorded.
-- Elaboration adds the unit to the name.
recordedP :: Expr -> P Expr
recordedP value = do
  keyword "recorded"
  name <- str
  unless (validName name) (fail ("a recording's name is letters, digits, spaces, - _ and ., and does not start with . or a space: " ++ show name))
  pure (Apply (Apply (Var "prelude.recorded") (StringLit name)) value)
  where
    validName n = not (null n) && take 1 n `notElem` [".", " "] &&
      all (\c -> isAlphaNum c || c `elem` (" -_." :: String)) n

-- `f :: T uses Async` on a signature is `async f :: T`: an adapter that
-- uses Async runs on the Async ability's default handler, the target's
-- native async, so its native code returns the target's task and gets no
-- handler argument for Async (docs/reference/language/abilities-mapping.md).
-- A unit that declares its own Async keeps the plain meaning.
asyncSugar :: [UnitMember] -> [UnitMember]
asyncSugar members
  | any ownAsync members = members
  | otherwise = map sugar members
  where
    ownAsync m = case m of
      AbilityMember a -> abilityName a == asyncAbilityName
      _ -> False
    isAsync t = abilityTypeName t == asyncAbilityName
    sugar m = case m of
      SignatureMember s used | any isAsync used -> AsyncMember s (filter (not . isAsync) used)
      AsyncMember s used -> AsyncMember s (filter (not . isAsync) used)
      _ -> m

-- Temporal propositions over the clock (LawSpec.Temporal): eventually
-- within d, P; always within d, P; never within d, P.
temporalP :: P Expr
temporalP = do
  kind <- (Left Eventually <$ try (keyword "eventually" *> keyword "within"))
    <|> (Left Always <$ try (keyword "always" *> keyword "within"))
    <|> (Right () <$ try (keyword "never" *> keyword "within"))
  micros <- spanP
  void (symbol ",")
  p <- expr
  pure $ case kind of
    Left k -> temporalExpr k micros p
    Right () -> temporalExpr Always micros (Unary "!" p)

-- `takes at most d` after an expression: a performance budget.
budgetStartP :: P ()
budgetStartP = try (keyword "takes" *> keyword "at" *> keyword "most")

budgetSuffix :: Expr -> P Expr
budgetSuffix e = do
  budgetStartP
  micros <- spanP
  pure (budgetExpr e micros)

-- A span of time for a temporal proposition or a budget: 2s, or 2 s.
spanP :: P Integer
spanP = lexeme $ do
  n <- L.decimal
  void (many (char ' '))
  constructor <- choice [constructor <$ try (string suffix <* notFollowedBy (alphaNumChar <|> char '_'))
    | (suffix, constructor) <- durationSuffixes]
  let micros = n * durationFactor constructor
  when (micros > durationLimit) (fail ("a duration is at most " ++ show durationLimit ++ " microseconds"))
  pure micros

-- A handler a law names: a spec handler, an ability (any lawful handler of
-- it), or `recording` of either.
handlerUseP :: P HandlerUse
handlerUseP = (keyword "recording" *> (UseRecording <$> handlerUseP))
  <|> builtinHandlerUseP
  <|> ((\n -> if startsUpper n then UseAbility n else UseHandler n) <$> ident)

-- The built-in handlers' readable names (LawSpec.Builtins): `virtual clock`
-- is lawspec.time's virtualClock, and `seeded random n` is lawspec.random's
-- seededRandom started at n.
builtinHandlerUseP :: P HandlerUse
builtinHandlerUseP =
  (UseHandler virtualClockHandler <$ try (keyword "virtual" *> keyword "clock"))
  <|> (UseHandler . seededHandlerName <$> (try (keyword "seeded" *> keyword "random") *> lexeme L.decimal))

-- uses A, B [fails with E], or fails with E alone: a signature's abilities.
usesP :: P [Type]
usesP = do
  -- A function named uses may follow a signature: only `uses Type` is a list.
  used <- option [] (try (keyword "uses" *> (typeP `sepBy1` symbol ",")))
  failure <- optional (try (keyword "fails" *> keyword "with") *> typeP)
  pure (used ++ [Applied failAbilityName t | Just t <- [failure]])

-- ability Name (a :: Type)* is (op :: Type)* [laws law*] end
abilityP :: P AbilityDeclaration
abilityP = do
  ((name, parameters, operations, abilityLaws'), range) <- withSpan $ do
    keyword "ability"
    name <- ident
    upper name
    parameters <- many $ sourceNode "type-parameter" (Just . id) $ parens $ do
      parameter <- ident
      unless (maybe False (isLower . fst) (uncons parameter)) (fail "type parameters must start with a lowercase letter")
      annotationP
      sourceNode "type-parameter-kind" (const (Just "Type")) (keyword "Type")
      pure parameter
    -- ability A with T is: native handlers of A are made with a T.
    resource <- optional (keyword "with" *> typeP)
    keyword "is"
    -- op :: T [fails with E]: an operation may fail, as a signature may.
    operations <- many (do
      op <- try (ident <* annotationP)
      ty <- typeP
      failure <- optional (try (keyword "fails" *> keyword "with") *> typeP)
      pure ((op, ty), (,) op <$> failure))
    abilityLaws' <- option [] (keyword "laws" *> many lawP)
    plainCloseP "ability"
    pure (name, (parameters, resource), operations, abilityLaws')
  pure (AbilityDeclaration name (fst parameters) (map fst operations) abilityLaws' range "" [f | (_, Just f) <- operations] (snd parameters))

-- handlers name is h1, h2, ... end
handlerSetP :: P HandlerSet
handlerSetP = do
  ((name, members), range) <- withSpan $ do
    keyword "handlers"
    name <- ident
    keyword "is"
    members <- qualifiedName `sepBy1` symbol ","
    plainCloseP "handlers"
    pure (name, members)
  pure (HandlerSet name members range)

-- handler name for Ability [with state s :: S start e] is (op x* is e end)* end
handlerP :: P HandlerDeclaration
handlerP = do
  ((name, ability, state, clauses), range) <- withSpan $ do
    keyword "handler"
    name <- ident
    keyword "for"
    ability <- typeP
    -- handler h for A, B: one handler, one state, for several abilities.
    also <- many (symbol "," *> typeP)
    state <- optional $ do
      try (keyword "with" *> keyword "state")
      s <- ident
      annotationP
      ty <- typeP
      keyword "start"
      start <- expr
      pure (s, ty, start)
    keyword "is"
    clauses <- many $ sourceNode "handler-operation" (Just . clauseOperation) $ do
      ((op, parameters, body), at) <- withSpan $ do
        op <- ident
        -- op by f: the clause is f, applied to the operation's values (and
        -- the state), as a model's or an actor's `on op by f` is.
        let byClause = do
              f <- try (keyword "by" *> qualifiedName <* notFollowedBy (keyword "is"))
              pure (op, [], Apply (Var clauseBy) (Var f))
            written = do
              parameters <- many ident
              keyword "is"
              body <- expr
              plainCloseP "operation"
              pure (op, parameters, body)
        byClause <|> written
      pure (HandlerClause op parameters body at)
    plainCloseP "handler"
    pure (name, (ability, also), state, clauses)
  pure (HandlerDeclaration name (fst ability) state clauses range "" (snd ability))
-- | Unit definitions have explicit parameter and result types. Law definitions
-- remain proposition blocks and are parsed separately by lawP.
functionDefinitionP :: P FunctionDefinition
functionDefinitionP = do
  ((name, arguments, result, requirements, body), range) <- withSpan $ do
    keyword "definition"
    name <- ident
    arguments <- some param
    annotationP
    result <- typeP
    requirements <- constraintsP
    body <- keyword "is" *> expr <* plainCloseP "definition"
    pure (name, arguments, result, requirements, body)
  pure (FunctionDefinition name arguments result requirements body range)

-- A definition with the abilities it says it uses, if it says.
definitionUsesP :: P (FunctionDefinition, Maybe [Type])
definitionUsesP = do
  ((name, arguments, result, requirements, used, body), range) <- withSpan $ do
    canonical <- canonicalP
    kind <- if canonical then ("function" <$ keyword "function") <|> ("procedure" <$ keyword "procedure") else "definition" <$ keyword "definition"
    name <- ident
    arguments <- some param
    result <- if canonical
      then (symbol "->" *> typeP) <|> (if kind == "procedure" then pure (Named "Unit") else fail "a function requires -> and a result type")
      else symbol "::" *> typeP
    requirements <- constraintsP
    used' <- optional (lookAhead (keyword "uses" <|> keyword "fails") *> usesP)
    let used = if canonical && kind == "function" then Just [] else used'
    when (canonical && kind == "function" && maybe False (not . null) used')
      (fail "a function is pure; declare a procedure for ability operations")
    body <- keyword "is" *> expr <* closeP kind
    pure (name, arguments, result, requirements, used, body)
  pure (FunctionDefinition name arguments result requirements body range, used)

-- Typed constants lower to ordinary checked definitions. Exhaustive constructor
-- coverage is admitted by the same compiler contract audit as hand-written code.
mappingP :: P [FunctionDefinition]
mappingP = do
  canonical <- canonicalP
  unless canonical empty
  ((name,keyType,resultType,writtenRows,writtenFallback), range) <- withSpan $ do
    keyword "mapping"
    name <- ident
    annotationP
    keyType <- typeAtom
    void (symbol "->")
    resultType <- typeP
    keyword "is"
    rows <- some (keyword "row" *> ((,) <$> literalP <* symbol "," <*> literalP))
    fallback <- optional (keyword "otherwise" *> literalP)
    closeP "mapping"
    pure (name,keyType,resultType,rows,fallback)
  rows <- mapM (\(key,value) -> (,) <$> contextualLiteral keyType key <*> contextualLiteral resultType value) writtenRows
  fallback <- traverse (contextualLiteral resultType) writtenFallback
  unless (all simpleKey (map fst rows) && case baseType keyType of RefinementApp _ _ -> False; _ -> True)
    (fail "mapping keys currently require a primitive type or unqualified payload-free constructor; resolved compound-key validation is not yet implemented")
  let equal a b = literalEquality a b
      keys = map fst rows
      outputs = map snd rows
  unless (all (\k -> equal k k) keys) (fail "mapping keys must be reflexive under Eq; NaN is not a key")
  unless (and [not (equal a b) | (index,a) <- zip [0 :: Int ..] keys, b <- drop (index + 1) keys])
    (fail "duplicate mapping key")
  let input = "lawspecMappingInput"
      select c yes no = foldl Apply (Var "prelude.select") [c,yes,no]
      lookupRows result = foldr (\(key,value) rest -> select (Binary "==" (Var input) (literalExpr key)) (literalExpr value) rest) result rows
      body = case fallback of
        Just other -> lookupRows (literalExpr other)
        Nothing | all enumKey keys -> MatchExpr (Var input)
          [MatchBranch tag [] (literalExpr value) | (ConstructorLiteral tag [],value) <- rows]
        Nothing | keyType == Named "Bool", any (equal (BoolLiteral True)) keys, any (equal (BoolLiteral False)) keys ->
          lookupRows (literalExpr (snd (head rows)))
        Nothing -> MatchExpr (Var input) []
      make n argument result expr = FunctionDefinition n [(input,argument)] result [] expr range
      -- Compare each typed output at execution, so aliases or contextual
      -- representations cannot make a compile-time grouping lose preimages.
      preimage = foldr (\(key,value) rest -> Apply (Apply (Var "prelude.append")
        (select (Binary "==" (Var input) (literalExpr value)) (ListLit [literalExpr key]) (ListLit []))) rest) (ListLit []) rows
      inverse = foldr (\(key,value) rest -> select (Binary "==" (Var input) (literalExpr value))
        (ConstructLit "Just" [literalExpr key]) rest) (ConstructLit "Nothing" []) rows
      eligibleInverse = all simpleKey outputs && case baseType resultType of
        RefinementApp _ _ -> False
        _ -> True
      unique = eligibleInverse && all (\v -> equal v v) outputs && and
        [not (equal a b) | (index,a) <- zip [0 :: Int ..] outputs, b <- drop (index + 1) outputs]
  pure ([make name keyType resultType body] ++
    [make (derived name "preimages") resultType (Applied "List" keyType) preimage | fallback == Nothing] ++
    [make (derived name "inverse") resultType (Applied "Maybe" keyType) inverse | unique && fallback == Nothing])
  where
    simpleKey (ConstructorLiteral name []) = '.' `notElem` name
    simpleKey (ConstructorLiteral _ _) = False
    simpleKey (ListLiteral _) = False
    simpleKey (RecordLiteral _) = False
    simpleKey (SetLiteral _ _) = False
    simpleKey _ = True
    contextualLiteral ty value = case (baseType ty, literalExpr value) of
      (Named name, expression) | primitive name /= Nothing -> case expression of
        ScalarLit scalar -> convert scalar
        Number n -> convert (SInteger "Integer" n)
        DecimalNumber c e -> convert (SDecimal c e)
        StringLit text -> convert (textScalar text)
        BoolLit b -> convert (SBool b)
        _ -> pure value
        where convert scalar = either fail (pure . ScalarLiteral) (convertScalar 64 name scalar)
      _ -> pure value
    enumKey (ConstructorLiteral _ []) = True
    enumKey _ = False
    derived ('"':'|':body) suffix = "\"|" ++ take (length body - 1) body ++ " " ++ suffix ++ "|"
    derived name suffix = name ++ (if suffix == "preimages" then "Preimages" else "Inverse")

literalEquality :: Literal -> Literal -> Bool
literalEquality a b = case (literalScalar a,literalScalar b) of
  (Just x,Just y) -> scalarEqual x y
  _ -> case (a,b) of
    (ConstructorLiteral x xs,ConstructorLiteral y ys) -> x == y && length xs == length ys && and (zipWith literalEquality xs ys)
    (ListLiteral xs,ListLiteral ys) -> length xs == length ys && and (zipWith literalEquality xs ys)
    (RecordLiteral xs,RecordLiteral ys) -> length xs == length ys &&
      length xs == length (nub (map fst xs)) && length ys == length (nub (map fst ys)) &&
      all (\(label,value) -> maybe False (literalEquality value) (lookup label ys)) xs
    _ -> False
  where
    literalScalar literal = case literal of
      IntLiteral n -> Just (SInteger "Integer" n)
      DecimalLiteral c e -> Just (SDecimal c e)
      TextLiteral text -> Just (textScalar text)
      BoolLiteral bool -> Just (SBool bool)
      ScalarLiteral scalar -> Just scalar
      _ -> Nothing

data UnitMember = DataMember DataTypeDeclaration | FamilyMember IndexedFamily | RefinementMember Refinement
  | WrapperMember Wrapper | WorkflowMember Workflow | ModelMember ModelDeclaration
  | SupervisorMember Supervisor
  | MailboxMember (String, Type, Span)
  | HandleMember (String, Span) | ProtocolMember Protocol | ScenarioMember Scenario
  | SignatureMember ((String, Type), Span) [Type] | AsyncMember ((String, Type), Span) [Type] | LawMember (Law, [HandlerUse])
  | DefinitionMember (FunctionDefinition, Maybe [Type]) | MappingMember [FunctionDefinition]
  | AbilityMember AbilityDeclaration | HandlerMember HandlerDeclaration
  | ResourceMember ResourceDeclaration | HarnessMember HarnessDeclaration | HandlerSetMember HandlerSet

memberSyntax :: UnitMember -> (String,Maybe String)
memberSyntax member = ("declaration." ++ kind,name)
  where
    (kind,name) = case member of
      DataMember d -> ("type",Just (dataTypeName d))
      FamilyMember f -> ("type",Just (familyName f))
      RefinementMember r -> ("refinement",Just (refinementName r))
      WrapperMember w -> ("wrapper",Just (wrapperName w))
      WorkflowMember w -> ("workflow",Just (workflowName w))
      ModelMember m -> (maybe "model" (const "actor") (modelActor m),Just (modelName m))
      SupervisorMember (Supervisor name _ _ _ _) -> ("supervisor",Just name)
      MailboxMember (name,_,_) -> ("mailbox",Just name)
      HandleMember (name,_) -> ("handle",Just name)
      ProtocolMember p -> ("protocol",Just (protocolName p))
      ScenarioMember s -> ("scenario",Just (scenarioName s))
      SignatureMember ((name,_),_) _ -> ("signature",Just name)
      AsyncMember ((name,_),_) _ -> ("async-signature",Just name)
      LawMember (law,_) -> ("law",Just (lawName law))
      DefinitionMember (definition,_) -> ("definition",Just (functionName definition))
      MappingMember definitions -> ("mapping",case definitions of d:_ -> Just (functionName d); [] -> Nothing)
      AbilityMember a -> ("ability",Just (abilityName a))
      HandlerMember h -> ("handler",Just (handlerName h))
      ResourceMember r -> ("resource",Just (prettyType (resourceType r)))
      HarnessMember h -> ("harness",Just (harnessName h))
      HandlerSetMember h -> ("handlers",Just (handlerSetName h))

unitNameP :: P String
unitNameP = foldr1 (\a b -> a ++ "." ++ b) <$>
  (lexeme ((:) <$> letterChar <*> many (alphaNumChar <|> char '_')) `sepBy1` symbol ".")

importP :: P Import
importP = sourceNode "import" (Just . importUnit) $ sourceNode "import-alias" (Just . importAlias) $ do
  ((target, alias, items), range) <- withSpan $ do
    keyword "import"
    target <- unitNameP
    alias <- optional (keyword "as" *> ident)
    items <- option [] (parens (importItemP `sepBy1` symbol ","))
    pure (target, alias, items)
  pure (Import target (maybe (baseName target) id alias) items range)

-- Import retains its existing law marker internally; only the delimiters are
-- synthetic. A backtick inside a phrase is part of the name.
importItemP :: P String
importItemP = sourceNode "import-item" Just $ do
  canonical <- canonicalP
  if canonical then ((\n -> "`" ++ n ++ "`") <$> (keyword "law" *> itemName)) <|> itemName
    else ((\n -> "`" ++ n ++ "`") <$> quoted) <|> ident
  where
    -- The preamble is read before aliases are installed. There is no field
    -- projection ambiguity in an import/export list, so parse qualification
    -- syntactically and leave target resolution to Imports.
    itemName = lexeme (intercalate "." <$> identRaw `sepBy1` char '.')

-- | export Money, domain.add, `commutative`: names this unit imports, offered
-- to the units that import it as if declared here (a facade). It is kept with
-- the imports, as an Import of no unit.
exportP :: P Import
exportP = sourceNode "export" (const Nothing) $ do
  (items, range) <- withSpan $ do
    keyword "export"
    canonical <- canonicalP
    if canonical then importItemP `sepBy1` symbol ","
      else (sourceNode "export-item" Just (((\n -> "`" ++ n ++ "`") <$> quoted) <|> qualifiedExport)) `sepBy1` symbol ","
  pure (Import "" "" items range)
  where
    qualifiedExport = lexeme $ try $ do
      first <- (:) <$> letterChar <*> many (alphaNumChar <|> char '_')
      rest <- optional (char '.' *> ((:) <$> letterChar <*> many (alphaNumChar <|> char '_')))
      pure (maybe first (\r -> first ++ "." ++ r) rest)

-- | Whether an Import is a unit's export line.
isExport :: Import -> Bool
isExport i = null (importUnit i)

-- | The unit header and its imports, read before the full parse so that imported
-- declaration arities are known.
preambleP :: P (String, [Import])
preambleP = do
  spaceP; keyword "unit"
  n <- unitNameP
  imports <- many (try importP <|> try exportP)
  pure (n, imports)

unitP :: P (Unit, [Import], [IndexedFamily], [Wrapper], [Workflow], [ModelDeclaration], ([Protocol], [Scenario]))
unitP = do
  (n, imports) <- preambleP
  members' <- many (sourceNodeBy memberSyntax $ (either FamilyMember DataMember <$> declarationP)
    <|> (WrapperMember <$> wrapperP)
    <|> (WorkflowMember <$> workflowP)
    <|> (ProtocolMember <$> (try (lookAhead (keyword "protocol" *> ident >>= upper)) *> protocolP))
    <|> (ScenarioMember <$> (try (lookAhead (keyword "scenario" *> quoted)) *> scenarioP))
    -- handle Name: a type whose values only adapters create.
    <|> (HandleMember <$> (try (lookAhead (keyword "handle" *> ident >>= upper)) *> withSpan (keyword "handle" *> ident)))
    -- `model` begins a model only before a name; it may name a function.
    <|> (ModelMember <$> (try (lookAhead (keyword "model" *> ident)) *> modelP))
    <|> (ModelMember <$> (try (lookAhead (keyword "actor" *> ident)) *> actorP))
    <|> (SupervisorMember <$> (try (lookAhead (keyword "supervisor" *> ident)) *> supervisorP))
    -- mailbox jobs of Job: a typed queue with many senders and one receiver.
    <|> (MailboxMember <$> (try (lookAhead (keyword "mailbox" *> ident *> keyword "of")) *>
          ((\((n, t), at) -> (n, t, at)) <$> withSpan ((,) <$> (keyword "mailbox" *> ident) <*> (keyword "of" *> typeP)))))
    <|> (RefinementMember <$> refinementP)
    -- ability Name ... and handler name for Ability ... (LawSpec.Abilities).
    <|> (AbilityMember <$> (try (lookAhead (keyword "ability" *> ident >>= upper)) *> abilityP))
    <|> (HandlerMember <$> (try (lookAhead (keyword "handler" *> ident *> keyword "for")) *> handlerP))
    -- resource Name is acquire ... release ... end: a law's resource.
    <|> (ResourceMember <$> (try (lookAhead (keyword "resource" *> ident >>= upper)) *> resourceP))
    -- handlers name is h1, h2 end: spec handlers that answer together.
    <|> (HandlerSetMember <$> (try (lookAhead (keyword "handlers" *> ident *> keyword "is")) *> handlerSetP))
    -- harness name for unit is ... end (LawSpec.Harness).
    <|> (HarnessMember <$> (try (lookAhead (keyword "harness" *> unitNameP *> keyword "for")) *> harnessP))
    <|> (MappingMember <$> mappingP)
    <|> (DefinitionMember <$> definitionUsesP)
    <|> try (AsyncMember <$> (keyword "async" *> withSpan ((,) <$> ident <* annotationP <*> typeP)) <*> usesP)
    <|> try (SignatureMember <$> withSpan ((,) <$> ident <* annotationP <*> typeP) <*> usesP)
    <|> (LawMember <$> lawUsingP))
  eof
  let members = asyncSugar members'
  when (length [() | HarnessMember _ <- members] > 1)
    (fail "a unit has at most one harness")
  let definitions = [d | DefinitionMember (d, _) <- members] ++ concat [ds | MappingMember ds <- members]
      signatures = [signature | member <- members, signature <- case member of
          SignatureMember s _ -> [s]
          AsyncMember s _ -> [s]
          _ -> []] ++
        [((functionName d, foldr Arrow (functionResult d) (map snd (functionArguments d))), functionSpan d) | d <- definitions]
  pure (Unit n (map fst signatures) [l | LawMember (l, _) <- members]
    [r | RefinementMember r <- members] [] [(name,range) | ((name,_),range) <- signatures]
    ([d | DataMember d <- members] ++ [DataTypeDeclaration name [] [] range Nothing | HandleMember (name, range) <- members])
    definitions [name | AsyncMember ((name, _), _) _ <- members] [] [] [] [name | HandleMember (name, _) <- members]
    [p | ProtocolMember p <- members] [s | SupervisorMember s <- members] [m | MailboxMember m <- members]
    [a | AbilityMember a <- members] [h | HandlerMember h <- members]
    ([(name, used) | SignatureMember ((name, _), _) used <- members, not (null used)] ++
     [(name, used) | AsyncMember ((name, _), _) used <- members, not (null used)] ++
     [(functionName d, used) | DefinitionMember (d, Just used) <- members])
    [(lawName l, using) | LawMember (l, using) <- members, not (null using)] [] []
    (case [h | HarnessMember h <- members] of h : _ -> Just h; [] -> Nothing) [] [r | ResourceMember r <- members]
    [s | HandlerSetMember s <- members], imports, [f | FamilyMember f <- members],
    [w | WrapperMember w <- members], [w | WorkflowMember w <- members], [m | ModelMember m <- members],
    ([p | ProtocolMember p <- members], [s | ScenarioMember s <- members]))

-- | A single source sees no other units, which is what the compiler API's
-- one-file requests and the tests need.
parseSource :: Source -> Either [Diagnostic] Unit
parseSource source = fst . fst <$> parseWith M.empty [] [] source
parseSourceCanonical :: Source -> Either [Diagnostic] Unit
parseSourceCanonical source = fst . fst <$> parseWith (M.singleton "profile:canonical" AliasHeader) [] [] source

-- | Parse sources that may import one another. Each unit sees the declaration
-- arities of the units it imports, qualified by alias and unqualified for
-- listed names; LawSpec.Imports resolves the names themselves.
parseSources :: [Source] -> Either [Diagnostic] [(Unit, [Import])]
parseSources = parseSourcesWith [] []

-- | With the built-in collection types a program uses, every other unit imports
-- those it does not declare itself (LawSpec.Collections). Each other built-in
-- unit (LawSpec.Time, LawSpec.Resilience) is imported, with its types, by the
-- sources it says use it.
parseSourcesWith :: [String] -> [(String, String, [String], String -> Bool)] -> [Source] -> Either [Diagnostic] [(Unit, [Import])]
parseSourcesWith collections implicit = parseSourcesWithBuiltins False collections implicit []
parseSourcesWithCanonical :: [String] -> [(String, String, [String], String -> Bool)] -> [Source] -> Either [Diagnostic] [(Unit, [Import])]
parseSourcesWithCanonical collections implicit = parseSourcesWithBuiltins True collections implicit []
-- | Versioned built-in sources are provided separately by the compiler. A user
-- path (including one starting with '<') never chooses a language profile.
parseSourcesWithBuiltins :: Bool -> [String] -> [(String, String, [String], String -> Bool)] -> [Source] -> [Source] -> Either [Diagnostic] [(Unit, [Import])]
parseSourcesWithBuiltins canonical collections builtins versioned userSources =
  fst <$> parseSourcesWithInventory False canonical collections builtins versioned userSources

parseSourcesWithBuiltinsAndSyntax :: Bool -> [String] -> [(String, String, [String], String -> Bool)] -> [Source] -> [Source] -> Either [Diagnostic] ([(Unit, [Import])],[SourceSyntax])
parseSourcesWithBuiltinsAndSyntax = parseSourcesWithInventory True

parseSourcesWithInventory :: Bool -> Bool -> [String] -> [(String, String, [String], String -> Bool)] -> [Source] -> [Source] -> Either [Diagnostic] ([(Unit, [Import])],[SourceSyntax])
parseSourcesWithInventory capture canonical collections builtins versioned userSources = do
  forM_ harnessSources $ \(Source path _, header) -> case header of
    Left message -> Left [Diagnostic "parse" message Nothing]
    Right (name, served) -> unless (served `elem` [n | (_, n, _) <- preambles])
      (Left [Diagnostic "harness" ("the harness " ++ name ++ " in " ++ path ++ " is for " ++ served ++ ", but there is no unit called " ++ served) Nothing])
  mapM_ acyclic (M.keys graph)
  let names = [n | (_, n, _) <- preambles]
  forM_ names $ \n -> when (length (filter (== n) names) > 1)
    (Left [Diagnostic "duplicate-unit" "unit names must be unique; prelude is reserved" Nothing])
  parsed <- mapM (\source -> either
    (const ((\((unit,_),syntax) -> (unit,syntax)) <$> parseWithProfilesInventory capture profile (imported source) [] [] source))
    (\(n, imports) -> (\(((u,_),_),syntax) -> ((u,imports),syntax)) <$> results Lazy.! n) (preamble source)) sources
  pure (map fst parsed,concatMap snd parsed)
  where
    allSources = versioned ++ userSources
    -- A harness in a file of its own is parsed with the unit it serves.
    (harnessSources, sources) = partitionHarnessSources allSources
    harnessesOf n = [source | (source, Right (_, served)) <- harnessSources, served == n]
    -- Parsed lazily in import order, so a unit sees its imports' indexed
    -- families under the names it uses for them.
    results = Lazy.fromList [(n, parseWithProfilesInventory capture profile (imported s) (families imports) (harnessesOf n) s) | (s, n, imports) <- preambles]
    families imports = concat
      [ [f{familyName = importAlias i ++ "." ++ familyName f} | f <- declared] ++
        [f | f <- declared, familyName f `elem` importItems i]
      | i <- imports, Just (Right ((_, declared),_)) <- [Lazy.lookup (importUnit i) results] ]
    preambles = [(s, n, imports) | s <- sources, Right (n, imports) <- [preamble s]]
    preamble source@(Source p s) = implicit source s <$> runReader (runParserT preambleP p s) (profile source M.empty)
    implicit source s (n, imports)
      | n `elem` ("prelude" : collectionsUnit : [unit | (unit, _, _, _) <- builtins]) = (n, imports)
      | otherwise =
          let local = M.keys (headers s) ++ concatMap importItems imports
              builtin namespaceOnly unit alias types =
                let items = [t | t <- types, t `notElem` local, t /= boundedArithmeticBlock]
                    origin = Location ("<" ++ unit ++ ">") 1 1
                -- A built-in with no types to list (lawspec.host) is imported
                -- whole, as the collections unit is for bounded arithmetic.
                in [Import unit alias items (Span origin origin) | namespaceOnly || not (null items) || unit == "lawspec.host" || boundedArithmeticBlock `elem` types]
              collectionNames = if canonicalSource source then canonicalCollectionNames collections else collections
          in (n, imports ++ builtin False collectionsUnit collectionsAlias collectionNames ++
               concat [builtin (canonicalSource source) unit alias types | (unit, alias, types, uses) <- builtins, uses s])
    graph = M.fromList [(n, imports) | (_, n, imports) <- preambles]
    -- Exports are computed lazily in import order, so an exported declaration
    -- may itself use its unit's imports.
    exports = Lazy.fromList [(n, reexported s imports (sourceExports (imported s) s)) | (s, n, imports) <- preambles]
    -- A unit's export line offers the arities of the names it lists, from the
    -- units it imports them from, and a listed type's constructors with it.
    reexported source imports (table, owners) =
      let listed = concat [importItems i | i <- imports, isExport i]
          from i item = case break (== '.') item of
            (alias, '.' : name) | alias == importAlias i -> Just name
            _ | item `elem` importItems i -> Just item
              | otherwise -> Nothing
          found = [ (name, t, o) | i <- imports, not (isExport i), item <- listed, Just name <- [from i item]
                  , Just raw <- [Lazy.lookup (importUnit i) exports], let (t,o) = collectionExports source i raw ]
          entries = M.fromList $ concat
            [ [(key, h) | (key, h) <- M.toList t, key == name || key == "constructor:" ++ name ||
                maybe False (\cs -> case break (== ':') key of
                  ("constructor", ':' : c) -> c `elem` cs
                  _ -> False) (lookup name o)]
            | (name, t, o) <- found ]
          ownersOut = [(name, cs) | (name, _, o) <- found, Just cs <- [lookup name o]]
      in (M.union table entries, owners ++ ownersOut)
    canonicalSource source = canonical && source `notElem` versioned
    profile source env = if canonicalSource source
      then M.insert "profile:canonical" AliasHeader env else M.delete "profile:canonical" env
    imported source = profile source $ case preamble source of
      Left _ -> M.empty
      Right (_, imports) -> M.unions
        [ M.insert ("alias:" ++ importAlias i) AliasHeader (M.unions
            [ M.fromList [(qualify (importAlias i) key, h) | (key, h) <- M.toList table]
            , M.fromList [(key, h) | let allowed = listed owners (importItems i), (key, h) <- M.toList table, allowed key] ])
        | i <- imports, Just raw <- [Lazy.lookup (importUnit i) exports], let (table,owners) = collectionExports source i raw ]
    collectionExports source i raw@(table,owners)
      | not (canonicalSource source) || importUnit i /= collectionsUnit = raw
      | otherwise =
          let hidden = ["Set","SortedSet","EqSet","constructor:SetItems","constructor:EqSetItems"]
              renamed = [(public,value) | (public,internal) <- canonicalCollectionTypes, Just value <- [M.lookup internal table]]
          in (M.union (M.fromList renamed) (foldr M.delete table hidden),
              [(public,[]) | (public,_) <- renamed] ++ [(name,cs) | (name,cs) <- owners, name `notElem` hidden])
    qualify alias key = case break (== ':') key of
      ("constructor", ':' : n) -> "constructor:" ++ alias ++ "." ++ n
      ("record", ':' : n) -> "record:" ++ alias ++ "." ++ n
      _ -> alias ++ "." ++ key
    -- Sets, as an import may list thousands of names.
    listed owners items =
      let names = S.fromList items
          ownerTable = M.fromListWith (\_ first -> first) owners
          constructors = S.fromList (concat [cs | item <- items, Just cs <- [M.lookup item ownerTable]])
      in \key -> case break (== ':') key of
        ("constructor", ':' : n) -> n `S.member` constructors
        ("record", ':' : n) -> n `S.member` names
        _ -> key `S.member` names
    acyclic start = go [start] start
      where
        go path n = forM_ (M.findWithDefault [] n graph) $ \i ->
          if importUnit i == start
            then Left [Diagnostic "import" ("import cycle: " ++ intercalate " -> " (reverse path ++ [start]))
              (Just (spanStart (importSpan i)))]
            else unless (importUnit i `elem` path) (go (importUnit i : path) (importUnit i))

-- | The unit a source declares.
sourceUnit :: Source -> Either String String
sourceUnit source@(Source p s) = case partitionHarnessSources [source] of
  -- A harness file belongs with the unit it serves.
  ([(_, header)], _) -> snd <$> header
  _ -> either (Left . errorBundlePretty) (Right . fst) (runReader (runParserT preambleP p s) M.empty)

-- | The headers a unit exports: its type, wrapper and refinement arities and its
-- constructor arities, with each data type's constructors.
sourceExports :: M.Map String Header -> Source -> (M.Map String Header, [(String, [String])])
sourceExports extra (Source _ s) =
  (M.filterWithKey (\key _ -> not ('.' `elem` key)) (literalHeaders s (M.union (headersWithProfile (M.member "profile:canonical" extra) s) extra)),
   constructorOwners extra s)

parseWith :: M.Map String Header -> [IndexedFamily] -> [Source] -> Source -> Either [Diagnostic] ((Unit, [Import]), [IndexedFamily])
parseWith = parseWithProfiles (\_ env -> env)

parseWithProfiles :: (Source -> M.Map String Header -> M.Map String Header) -> M.Map String Header -> [IndexedFamily] -> [Source] -> Source -> Either [Diagnostic] ((Unit, [Import]), [IndexedFamily])
parseWithProfiles profile extra importedFamilies harnessFiles source =
  fst <$> parseWithProfilesInventory False profile extra importedFamilies harnessFiles source

parseWithProfilesInventory :: Bool -> (Source -> M.Map String Header -> M.Map String Header) -> M.Map String Header -> [IndexedFamily] -> [Source] -> Source -> Either [Diagnostic] (((Unit, [Import]), [IndexedFamily]),[SourceSyntax])
parseWithProfilesInventory capture profile extra importedFamilies harnessFiles (Source p s) =
 case runReader (MP.runParserT (runStateT unitP initialInventory) p s) environment of
  Left e -> let offset = errorOffset (NE.head (bundleErrors e))
                (_,state) = reachOffset offset (bundlePosState e)
                pos = pstateSourcePos state
            in Left [Diagnostic "parse" (errorBundlePretty e)
                 (Just (Location (sourceName pos) (unPos (sourceLine pos)) (unPos (sourceColumn pos))))]
  Right ((parsed, imports, families, wrappers, workflows, models, (protocols, scenarios)),recorded) -> do
    let u0 = parsed { functionDefinitions =
          [d { functionSource = Just (unitName parsed,functionName d) } | d <- functionDefinitions parsed] }
    -- A harness file is read with the names of the unit it serves.
    separate <- mapM (\harness@(Source hp hs) -> either (\e -> Left [Diagnostic "parse" (errorBundlePretty e) Nothing]) Right
      (runReader (MP.runParserT (runStateT harnessFileP initialInventory) hp hs) (profile harness environment))) harnessFiles
    u <- case (unitHarness u0, map fst separate) of
      (_, []) -> pure u0
      (Nothing, [h]) -> pure u0 { unitHarness = Just h }
      _ -> Left [Diagnostic "harness" ("the unit " ++ unitName u0 ++ " has more than one harness; a unit has at most one") Nothing]
    domained <- either (\(at, message) -> Left [Diagnostic "domain" message at]) Right
      (elaborateDomain wrappers workflows
        (if M.member "profile:canonical" environment then u else railwayUnit u))
    -- Models read typestate from flow parameters, so they come first.
    modeled <- either (\(at, message) -> Left [Diagnostic "model" message (spanStart <$> at)]) Right
      (elaborateModels models domained >>= \m -> m <$ checkSupervisors m)
    programs <- either (\(at, message) -> Left [Diagnostic "scenario" message (spanStart <$> at)]) Right
      (checkScenarios protocols scenarios modeled >>= \cyclic -> mapM (uncurry (toProgram modeled)) (zip cyclic scenarios))
    let scenarioed = modeled { machines = [m { machineScenarios = [p | p <- programs, programMachine p == machineName m] }
                                          | m <- machines modeled] }
    -- Abilities are elaborated after imports (LawSpec.Compile), so a unit
    -- sees the abilities and handlers it imports.
    (families', flowed) <- either (\(at, message) -> Left [Diagnostic "flow" message at]) Right
      (desugarFlows importedFamilies families scenarioed)
    elaborated <- either (\message -> Left [Diagnostic "indexed" (p ++ ": " ++ message) Nothing]) Right
      (elaborateFamiliesWith importedFamilies families' flowed)
    let inventory = if capture then
          sourceSyntax p (unitName parsed) (maybe [] reverse recorded) :
          [sourceSyntax hp (harnessFor harness) (maybe [] reverse nodes)
            | (Source hp _,(harness,nodes)) <- zip harnessFiles separate]
          else []
    pure (((elaborated, imports), families'),inventory)
  where
    initialInventory = if capture then Just [] else Nothing
    environment = literalHeaders s (M.union (headersWithProfile (M.member "profile:canonical" extra) s) extra)

-- Sources that hold a harness rather than a unit, each with its header.
partitionHarnessSources :: [Source] -> ([(Source, Either String (String, String))], [Source])
partitionHarnessSources sources =
  ( [(source, header source) | source <- sources, isHarness source]
  , [source | source <- sources, not (isHarness source)] )
  where
    isHarness (Source p s) = either (const False) (const True)
      (runReader (runParserT (spaceP *> keyword "harness") p s) M.empty)
    header (Source p s) = either (Left . errorBundlePretty) Right (runReader (runParserT harnessHeaderP p s) M.empty)

-- | Read declaration arities before parsing applications, including forward references.
-- Strings, quoted law names and comments are consumed atomically.
headers :: String -> M.Map String Header
headers = headersWithProfile False
headersWithProfile :: Bool -> String -> M.Map String Header
headersWithProfile canonical source = M.fromList (scan tokens) where
  tokens = either (const []) id $ runReader (runParserT (spaceP *> many token <* eof) "headers" source) (if canonical then M.singleton "profile:canonical" AliasHeader else M.empty)
  token = try phraseNameRaw <|> ("<string>" <$ try str) <|> ("<quoted>" <$ try quotedOrInfixToken)
      <|> lexeme ((:) <$> letterChar <*> many (alphaNumChar <|> char '_'))
      <|> symbol "::" <|> ((:[]) <$> lexeme anySingle)
  -- A named closer must not consume the next declaration as a type header.
  scan ("end":"type":rest) | canonical = scan rest
  scan ("unit":_:rest) = scan (dropUnit rest)
  scan ("of":"type":rest) = scan rest
  scan ("refinement":n:rest) = let (ks,remaining) = parametersH rest in (n,RefinementHeader ks):scan remaining
  scan ("type":n:rest) = let (ks,remaining) = parametersH rest in (n,DataHeader ks):scan remaining
  scan ("wrapper":n:rest) = let (ks,remaining) = parametersH rest in (n,DataHeader ks):scan remaining
  scan ("handle":n:rest) | maybe False (isUpper . fst) (uncons n) = (n,DataHeader []):scan rest
  scan ("ability":n:rest) | maybe False (isUpper . fst) (uncons n) = let (ks,remaining) = parametersH rest in (n,DataHeader ks):scan remaining
  scan (_:rest) = scan rest
  scan [] = []
  dropUnit (".":_:rest) = dropUnit rest
  dropUnit rest = rest
  parametersH ("(":rest) = let (inside,remaining) = group (1 :: Int) [] rest
                               (ks,remaining') = parametersH remaining
                           in ((case inside of [_ ,"::","Type"] -> True; [_,"of","type","Type"] -> True; _ -> False):ks,remaining')
  parametersH rest = ([],rest)
  group _ acc [] = (reverse acc,[])
  group depth acc (t:rest)
    | t == ")" && depth == 1 = (reverse acc,rest)
    | otherwise = group (depth + if t == "(" then 1 else if t == ")" then -1 else 0) (t:acc) rest

-- | Each data type or wrapper with its constructor names.
constructorOwners :: M.Map String Header -> String -> [(String, [String])]
constructorOwners extra source = either (const []) id $
  runReader (runParserT scan "constructor owners" source) (M.union (headersWithProfile (M.member "profile:canonical" extra) source) extra)
  where
    scan = spaceP *> (concat <$> many ((pure . owner <$> try dataTypeP)
      <|> ((\w -> [(wrapperName w, [wrapperName w])]) <$> try wrapperP) <|> ([] <$ token))) <* eof
    owner d = (dataTypeName d, map dataConstructorName (dataTypeConstructors d))
    token = void (try phraseNameRaw) <|> void (try str) <|> try quotedOrInfixToken <|>
      void (lexeme ((:) <$> letterChar <*> many (alphaNumChar <|> char '_'))) <|> void (lexeme anySingle)

-- | Reuse the declaration parser to discover fixture constructor arities. This
-- pass skips other tokens atomically; the full parse remains authoritative for
-- errors and source ranges, including malformed declarations.
literalHeaders :: String -> M.Map String Header -> M.Map String Header
literalHeaders source initial = case runReader (runParserT scan "constructor headers" source) initial of
  Left _ -> initial
  Right declarations -> M.union (M.fromList (
    [("record:" ++ dataTypeName d, RecordHeader (dataConstructorFields c))
      | Just d <- declarations, [c] <- [dataTypeConstructors d], dataConstructorName c == dataTypeName d,
        not (M.member "profile:canonical" initial) || dataConstructorSpan c == dataTypeSpan d] ++
    [("constructor:" ++ dataConstructorName c, DataHeader (replicate (length (dataConstructorFields c)) True))
      | Just d <- declarations, c <- dataTypeConstructors d])) initial
  where
    -- A wrapper's constructor shares its name and takes the single value field.
    wrapped w = DataTypeDeclaration (wrapperName w) (wrapperParameters w)
      [ConstructorDeclaration (wrapperName w) [("value", wrapperBase w)] (wrapperSpan w) []] (wrapperSpan w) Nothing
    scan = spaceP *> many ((Just <$> try dataTypeP) <|> (Just . wrapped <$> try wrapperP) <|> (Nothing <$ token)) <* eof
    token = void (try phraseNameRaw) <|> void (try str) <|> try quotedOrInfixToken <|>
      void (lexeme ((:) <$> letterChar <*> many (alphaNumChar <|> char '_'))) <|> void (lexeme anySingle)

-- Harness units (LawSpec.Harness). A harness is the implementation plane of
-- a unit: it chooses how laws are tested and can never change what they
-- mean, so it may not declare laws, definitions, abilities, handlers,
-- types or signatures. It lives in its own file, or after a unit's members.
--
--   harness name for unit is
--     strategy orders :: Order is frequency 9 small, 1 bulk end
--     test with fakeGateway, native
--     for law `charges once`
--       use orders for o
--       cover 10% "empty basket" when isEmpty o.items
--     share database per unit
--     benchmark `checkout` is checkout sampleOrder end
--   end
--
-- A setting that carries an expression ends at the end of its line.
harnessP :: P HarnessDeclaration
harnessP = sourceNode "harness" (Just . harnessName) $ do
  ((name, served, items), range) <- withSpan $ do
    keyword "harness"
    name <- unitNameP
    keyword "for"
    served <- unitNameP
    keyword "is"
    items <- many harnessItemP
    plainCloseP "harness"
    pure (name, served, items)
  pure (HarnessDeclaration name served items range)

-- A harness in a file of its own.
harnessFileP :: P HarnessDeclaration
harnessFileP = spaceP *> harnessP <* eof

-- The harness's name and the unit it serves, read before the full parse.
harnessHeaderP :: P (String, String)
harnessHeaderP = do
  spaceP
  keyword "harness"
  name <- unitNameP
  keyword "for"
  served <- unitNameP
  pure (name, served)

harnessItemP :: P HarnessItem
harnessItemP = forbidden *> choice
  [ HarnessStrategy <$> strategyP
  , do ((names, settings), range) <- withSpan $ do
         try (keyword "for" *> (keyword "laws" <|> keyword "law"))
         names <- lawNameP `sepBy1` symbol ","
         settings <- many (forbidden *> harnessSettingSpanP)
         pure (names, settings)
       pure (HarnessFor names settings range)
  , do ((resource, scope), range) <- withSpan $ do
         keyword "share"
         resource <- ident
         keyword "per"
         scope <- choice [SharePerGroup <$ keyword "group", SharePerUnit <$ keyword "unit", SharePerRun <$ keyword "run"]
         pure (resource, scope)
       pure (HarnessShare resource scope range)
  , do ((name, body), range) <- withSpan (sourceNode "benchmark" (Just . fst) ((,) <$> (keyword "benchmark" *> quoted) <*> (keyword "is" *> expr <* plainCloseP "benchmark")))
       pure (HarnessBenchmark name body range)
  , HarnessOrderRandom . snd <$> withSpan (try (keyword "order" *> keyword "random"))
  , HarnessParallel . snd <$> withSpan (keyword "parallel")
  , uncurry HarnessDefault <$> harnessSettingSpanP ]
  where
    -- What only the law plane may declare.
    declaration = choice
      [ "law" <$ keyword "law", "definition" <$ keyword "definition", "ability" <$ keyword "ability"
      , "handler" <$ keyword "handler", "type" <$ keyword "type", "refinement" <$ keyword "refinement"
      , "resource" <$ keyword "resource", "signature" <$ try (ident *> symbol "::") ]
    -- The declaration is consumed first, so the error is this one.
    forbidden = optional (lookAhead declaration) >>= \found -> case found of
        Nothing -> pure ()
        Just what -> declaration *> fail ("a harness cannot declare a " ++ what ++ ": laws, definitions, abilities, handlers and types " ++
          "belong to the unit it serves; a harness only chooses how that unit's laws are tested")

harnessSettingSpanP :: P (HarnessSetting, Span)
harnessSettingSpanP = withSpan harnessSettingP

harnessSettingP :: P HarnessSetting
harnessSettingP = choice
  [ do keyword "witness"
       canonical <- canonicalP
       unless canonical (fail "harness witnesses require the 1.0-rc.1 profile")
       value <- regionExpr [["for"]]
       keyword "for"
       root <- option [] (try (keyword "definition" *> symbol "." *> pure ["definition"]))
       path <- lexeme (identRaw `sepBy1` char '.')
       pure (WitnessSetting (root ++ path) value [])
  , do strategy <- keyword "use" *> ident
       keyword "for"
       canonical <- canonicalP
       target <- if canonical then do
         root <- option [] (try (keyword "definition" *> symbol "." *> pure ["definition"]))
         path <- lexeme (identRaw `sepBy1` char '.')
         pure (intercalate "." (root ++ path))
         else ident
       pure (UseStrategy strategy target)
  , TestWith <$> (try (keyword "test" *> keyword "with") *> (ident `sepBy1` symbol ","))
  , do keyword "cover"
       percent <- lexeme L.decimal
       void (symbol "%")
       when (percent > 100) (fail "a cover requirement is a percentage, at most 100%")
       label <- str
       keyword "when"
       CoverSetting percent label <$> regionExpr []
  , do keyword "classify"
       e <- regionExpr [["as"]]
       keyword "as"
       ClassifySetting e <$> str
  , LabelSetting <$> (keyword "label" *> regionExpr [])
  , TargetMaximize <$> (try (keyword "target" *> keyword "maximize") *> regionExpr [])
  , TagsSetting <$> (keyword "tags" *> (tagP `sepBy1` symbol ","))
  , SkipSetting <$> (keyword "skip" *> str)
  , KnownFailingSetting <$> (try (keyword "known" *> keyword "failing") *> str)
  , TimeoutSetting <$> (keyword "timeout" *> durationP)
  , RepeatSetting <$> (keyword "repeat" *> positive "repeat" <* optional (keyword "times"))
  , RetryFlakySetting <$> (try (keyword "retry" *> keyword "flaky") *> positive "retry flaky" <* optional (keyword "times")) ]
  where
    tagP = lexeme ((:) <$> letterChar <*> many (alphaNumChar <|> oneOf ("_-" :: String)))
    positive what = do
      n <- lexeme L.decimal
      when (n < 1) (fail (what ++ " takes a whole number of at least 1"))
      pure n
    -- 2 s, 500 ms, 1 min: in milliseconds.
    durationP = do
      n <- lexeme L.decimal
      factor <- choice
        [ 1 <$ (keyword "ms" <|> keyword "milliseconds" <|> keyword "millisecond")
        , 60000 <$ (keyword "min" <|> keyword "minutes" <|> keyword "minute")
        , 1000 <$ (keyword "s" <|> keyword "seconds" <|> keyword "second") ]
      when (n < 1) (fail "a timeout is at least 1 ms")
      pure (n * factor)

-- strategy name :: T is gen end
strategyP :: P StrategyDeclaration
strategyP = sourceNode "strategy" (Just . strategyName) $ do
  ((name, ty, body), range) <- withSpan $ do
    keyword "strategy"
    name <- ident
    unless (maybe False (isLower . fst) (uncons name)) (fail "strategy names start with a lowercase letter")
    annotationP
    ty <- typeP
    keyword "is"
    body <- genP
    plainCloseP "strategy"
    pure (name, ty, body)
  pure (StrategyDeclaration name ty body range)

-- gen [such that p [at most n discards]], where p names the value `it`.
genP :: P Gen
genP = do
  g <- genCoreP
  option g $ do
    try (keyword "such" *> keyword "that")
    p <- regionExpr [["at", "most"], ["end"], [")"]]
    limit <- option 100 (try (keyword "at" *> keyword "most") *> lexeme L.decimal <* keyword "discards")
    when (limit < 1) (fail "at most takes a whole number of at least 1")
    pure (GenSuchThat g p limit)

genCoreP :: P Gen
genCoreP = choice
  [ GenFrequency <$> (keyword "frequency" *> (((,) <$> weight <*> genAtomP) `sepBy1` symbol ","))
  , do keyword "bind"
       x <- ident
       annotationP
       ty <- typeP
       keyword "from"
       from <- genAtomP
       keyword "in"
       GenBind x ty from <$> genP
  , GenOneOf <$> (try (keyword "one" *> keyword "of") *> (regionExpr [[","], ["such", "that"], ["end"], [")"]] `sepBy1` symbol ","))
  , genAtomP ]
  where
    weight = do
      n <- lexeme L.decimal
      when (n < 1) (fail "a frequency weight is a whole number of at least 1")
      pure n

genAtomP :: P Gen
genAtomP = choice
  [ keyword "any" *> (GenAny <$> optional (try (lookAhead (satisfy isUpper <|> char '(')) *> typeAtom))
  , parens genP
  , GenNamed <$> ident ]

-- An expression that ends at the end of its line, or before the first of
-- the stop phrases outside strings, brackets and parentheses. Harness
-- settings follow one another without delimiters, so an expression must not
-- read the next setting as arguments.
regionExpr :: [[String]] -> P Expr
regionExpr stops = do
  canonical <- canonicalP
  st <- getParserState
  let input = stateInput st
      region = cut canonical 0 input
  when (all (`elem` (" \t\r" :: String)) region) (fail "expected an expression")
  inventory <- get
  (after, result) <- lift (lift (runParserT' (runStateT (expr <* eof) inventory) st { stateInput = region }))
  case result of
    Left bundle -> case bundleErrors bundle of
      e NE.:| _ -> parseError e
    Right (e,recorded) -> do
      put recorded
      setParserState st { stateInput = drop (length region) input, stateOffset = stateOffset after }
      spaceP
      pure e
  where
    cut :: Bool -> Int -> String -> String
    cut _ _ [] = []
    cut _ _ ('\n' : _) = []
    cut _ 0 rest@('-' : '-' : _) = takeWhile (/= '\n') rest `seq` []
    cut True depth ('"' : '|' : rest) = let (inside, after) = phraseBody rest in "\"|" ++ inside ++ cut True depth after
    cut True depth ('`' : '|' : rest) = let (inside, after) = phraseBody rest in "`|" ++ inside ++ cut True depth after
    cut True depth ('`' : rest) = '`' : cut True depth rest
    cut canonical depth ('"' : rest) = let (inside, after) = stringBody rest in '"' : inside ++ cut canonical depth after
    cut canonical depth ('`' : rest) = let (inside, after) = break (== '`') rest in '`' : inside ++ take 1 after ++ cut canonical depth (drop 1 after)
    cut canonical depth s@(c : rest)
      | depth == 0, Just _ <- stopAt s = []
      | c `elem` ("([{" :: String) = c : cut canonical (depth + 1) rest
      | c `elem` (")]}" :: String) = if depth == 0 then (if [")"] `elem` stops then [] else c : cut canonical depth rest) else c : cut canonical (depth - 1) rest
      | otherwise = c : cut canonical depth rest
    phraseBody ('\\' : x : rest) = let (a,b) = phraseBody rest in ('\\' : x : a,b)
    phraseBody ('|' : rest) = ("|",rest)
    phraseBody (x : rest) = let (a,b) = phraseBody rest in (x:a,b)
    phraseBody [] = ([],[])
    stringBody ('\\' : x : rest) = let (a, b) = stringBody rest in ('\\' : x : a, b)
    stringBody ('"' : rest) = ("\"", rest)
    stringBody (x : rest) = let (a, b) = stringBody rest in (x : a, b)
    stringBody [] = ([], [])
    -- A stop phrase begins here, as whole words.
    stopAt s = case [stop | stop <- stops, matches stop s] of
      found : _ -> Just found
      [] -> Nothing
    matches [] _ = True
    matches (w : ws) s
      | w == "," = case s of ',' : rest -> matches ws (dropWhile (== ' ') rest); _ -> False
      | w == ")" = False
      | otherwise = case stripWord w s of
          Just rest -> matches ws (dropWhile (== ' ') rest)
          Nothing -> False
    stripWord w s
      | take (length w) s == w, not (wordChar (drop (length w) s)) = Just (drop (length w) s)
      | otherwise = Nothing
    wordChar (c : _) = isAlphaNum c || c == '_'
    wordChar [] = False
