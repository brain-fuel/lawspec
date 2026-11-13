-- | Record rules, validators and masking. A record's rules are the
-- restrictions its fields already carry (ranges, regexes, lists, lengths,
-- named formats, any checked definition) and its named whole-record rules.
-- Each has a stable id, `<field>.<suffix>` or the rule's name. From them this
-- module generates, as ordinary checked definitions and laws that every
-- target then compiles like the user's own:
--
--   * `<Record>Draft`: the record's fields at their base types, which can
--     hold a value that breaks the rules;
--   * `violationsOf<Record>`: every rule a draft breaks, in declaration
--     order, as `Violation`s (rule id, field, message);
--   * `validate<Record>`: the record, or those violations;
--   * `draftOf<Record>`: a record's draft;
--   * for each field rule, a law that breaking it alone is reported as it
--     alone; for the record, a law that every value passes;
--   * for a record with a masking block, `masked<Record>` and
--     `masked<Record>Draft`, and a law per masked field that what the mask
--     hides shows in no rendering and no violation message.
--
-- They are generated for a record that a source of the program names them
-- for, or that has a masking block; a record nobody validates costs nothing.
--
-- Precedent. Jakarta Bean Validation's `validate` returns every violation,
-- identified by property path and constraint type; Zod's issues are
-- `{code, path, message}`. LawSpec's id is explicit and names-only, so it
-- survives reordering and a rename is a visible change. The validator takes a
-- draft and gives the refined record ("parse, don't validate"), and its
-- construction is proved by the totality audit like any definition's: the
-- record is built under one condition per rule. "Breaking one rule alone" has
-- no library precedent found (Hypothesis and jetCheck generate from one
-- description); it is a generated law whose guard the vacuity check reads, so
-- a rule that cannot be broken alone is reported, never passed silently.
-- ref:DEC-record-rules ref:DEC-masking
module LawSpec.ContractRules
  ( rulesUnit, rulesAlias, rulesTypes, rulesSource, usesRules, programUsesRules, ruleOperation, ruleOperations
  , contractDemand, contractNames, draftName, validatorName, violationsName, draftOfName, maskedName, maskedDraftName
  , Rule(..), recordRules, maskSentinel, elaborateContracts
  ) where

import Control.Monad (forM, forM_, unless, when)
import Data.Char (isAlphaNum, isLower, isUpper)
import Data.List (isInfixOf, isPrefixOf, isSuffixOf, nub, stripPrefix)
import qualified Data.Map.Strict as M
import Data.Maybe (fromMaybe)
import LawSpec.Formats (formatDescription, formatNames, formatPattern)
import LawSpec.Model
import LawSpec.RuleNames (rulesAlias, rulesUnit)
import LawSpec.Scalar (isInteger)
import LawSpec.SourceTokens (Token(..), TokenKind(..), sourceTokens)

-- | The unit's types, imported by every source that uses rules.
rulesTypes :: [String]
rulesTypes = ["Violation"]

-- | prelude.<op> and the definition implementing it.
ruleOperations :: [(String, String)]
ruleOperations =
  [ ("violatedRules", "rulesViolated"), ("failsWithRule", "rulesFailsWith")
  , ("messagesHide", "rulesMessagesHide"), ("maskEmail", "rulesMaskEmail"), ("maskLast", "rulesMaskLast") ]

ruleOperation :: String -> Maybe String
ruleOperation name = lookup name ruleOperations

draftName, validatorName, violationsName, draftOfName, maskedName, maskedDraftName :: String -> String
draftName record = record ++ "Draft"
validatorName record = "validate" ++ record
violationsName record = "violationsOf" ++ record
draftOfName record = "draftOf" ++ record
maskedName record = "masked" ++ record
maskedDraftName record = "masked" ++ record ++ "Draft"

-- | Every name generated for a record.
contractNames :: String -> [String]
contractNames record = map ($ record) [draftName, validatorName, violationsName, draftOfName, maskedName, maskedDraftName]

-- | The words of a source outside its comments, texts and phrase names.
codeWords :: String -> [String]
codeWords text =
  words (map (\c -> if isAlphaNum c || c `elem` ("._" :: String) then c else ' ')
    (concat [if tokenKind token `elem` [LiteralToken, PhraseToken, CommentToken] then " " else tokenText token ++ " " | token <- sourceTokens text]))

-- | The generated names a source asks for: a word shaped like one. Whether a
-- record of that name exists is decided where the record is declared.
contractDemand :: String -> [String]
contractDemand text = nub (filter shaped (map unqualified (codeWords text)))
  where
    unqualified word = reverse (takeWhile (/= '.') (reverse word))
    shaped word = any (\prefix -> maybe False startsUpperCase (stripPrefix prefix word)) ["validate", "violationsOf", "draftOf", "masked"] ||
      (startsUpperCase word && "Draft" `isSuffixOf` word && word /= "Draft")
    startsUpperCase word = case word of
      first : _ -> isUpper first
      [] -> False

-- | Whether a source needs the unit: it names a generated definition or
-- Violation, has a masking block, or asks which rule a validation fails with.
usesRules :: String -> Bool
usesRules text =
  let tokens = codeWords text
      triples = zip3 tokens (drop 1 tokens) (drop 2 tokens)
  in any (`elem` tokens) ("Violation" : "masking" : ["prelude." ++ operation | (operation, _) <- ruleOperations]) ||
     or [a == "fails" && b == "with" && maybe False isLower (firstOf c) | (a, b, c) <- triples] ||
     or [a == "prelude" && b == "." && c `elem` map fst ruleOperations | (a, b, c) <- triples]
  where firstOf word = case word of first : _ -> Just first; [] -> Nothing

-- | Whether a program needs the rules unit: a source uses rules in so many
-- words, or names what is generated for a type some source declares. A
-- program whose own step is called validateOrder, with no type Order, does
-- not.
programUsesRules :: [String] -> Bool
programUsesRules texts = any usesRules texts || any (`elem` declared) (concatMap (concatMap records . contractDemand) texts)
  where
    declared = concat [[name | (keyword, name) <- zip tokens (drop 1 tokens), keyword == "type"] | text <- texts, let tokens = codeWords text]
    records name = [rest | prefix <- ["validate", "violationsOf", "draftOf", "masked"], Just rest <- [stripPrefix prefix name]] ++
      [reverse rest | Just rest <- [stripPrefix (reverse "Draft") (reverse name)]] ++
      [reverse rest | Just masked <- [stripPrefix "masked" name], Just rest <- [stripPrefix (reverse "Draft") (reverse masked)]]

-- | The marker a no-leak law hides in a masked field. No rendering or
-- message may show it.
maskSentinel :: String
maskSentinel = "<lawspec-masked-sentinel>"

rulesSource :: String
rulesSource = unlines
  [ "unit " ++ rulesUnit
  , ""
  , "-- One broken rule: its stable id, the field it restricts (Absent for a rule"
  , "-- of the whole record) and what to tell a person."
  , "type Violation is a record{"
  , "  rule :: Text,"
  , "  field :: Maybe Text,"
  , "  message :: Text}"
  , "end type"
  , ""
  , "-- The ids of the broken rules, in order."
  , "function rulesViolated (violations :: List Violation) -> List Text is"
  , "  first matching case of violations :"
  , "  when Nil then Nil"
  , "  when Cons violation rest then Cons violation.rule (rulesViolated rest)"
  , "  end case"
  , "end function"
  , ""
  , "-- A validation that fails with exactly this rule."
  , "function rulesFailsWith (rule :: Text) (result :: Either (List Violation) a) -> Bool is"
  , "  first matching case of result :"
  , "  when Left violations then rulesViolated violations = [rule]"
  , "  when Right value then false"
  , "  end case"
  , "end function"
  , ""
  , "-- No message shows the marker."
  , "function rulesMessagesHide (marker :: Text) (violations :: List Violation) -> Bool is"
  , "  first matching case of violations :"
  , "  when Nil then true"
  , "  when Cons violation rest then"
  , "    if violation.message contains marker then false else rulesMessagesHide marker rest end if"
  , "  end case"
  , "end function"
  , ""
  , "function rulesLastPiece (pieces :: List Text) (fallback :: Text) -> Text is"
  , "  first matching case of pieces :"
  , "  when Nil then fallback"
  , "  when Cons piece rest then rulesLastPiece rest piece"
  , "  end case"
  , "end function"
  , ""
  , "-- An address shown as the first character before its first at sign, three"
  , "-- stars, and what follows its last at sign. A text without an at sign is"
  , "-- not shown at all."
  , "function rulesMaskEmail (value :: Text) -> Text is"
  , "  first matching case of prelude.split \"@\" value :"
  , "  when Nil then \"***\""
  , "  when Cons name rest then"
  , "    (first matching case of rest :"
  , "     when Nil then \"***\""
  , "     when Cons next more then prelude.take 1 name ++ \"***@\" ++ rulesLastPiece more next"
  , "     end case)"
  , "  end case"
  , "end function"
  , ""
  , "-- A text shown as three stars and its last characters. A text no longer"
  , "-- than that is not shown at all."
  , "function rulesMaskLast (count :: Integer) (value :: Text) -> Text is"
  , "  if prelude.length value <= count then \"***\""
  , "  else \"***\" ++ prelude.drop (prelude.length value - count) value end if"
  , "end function"
  , ""
  , "law \"|a mask of the last characters shows only them| is"
  , "  definition :"
  , "    for all (hidden :: Text) (other :: Text) (shown :: Text) =>"
  , "      rulesMaskLast (prelude.length shown) (\"a\" ++ hidden ++ shown) ="
  , "        rulesMaskLast (prelude.length shown) (\"b\" ++ other ++ shown) end for all"
  , "  end definition"
  , "end law"
  , ""
  , "law \"|an address mask shows only the first character and the domain| is"
  , "  definition :"
  , "    for all (hidden :: Text) (other :: Text) =>"
  , "      rulesMaskEmail (\"a\" ++ hidden ++ \"@example.org\") = rulesMaskEmail (\"a\" ++ other ++ \"@example.org\")"
  , "      and rulesMaskEmail (\"a\" ++ hidden ++ \"@example.org\") = \"a***@example.org\" end for all"
  , "  end definition"
  , "end law"
  , ""
  , "end unit" ]

-- | One rule of a record. The predicate is over the record's field names.
data Rule = Rule
  { ruleId :: String, ruleField :: Maybe String, ruleKind :: String
  , ruleMessage :: String, rulePredicate :: Expr
  } deriving (Eq, Show)

-- | The conjuncts of a restriction, each without its source span.
conjuncts :: Expr -> [Expr]
conjuncts expression = case unlocated expression of
  Binary "&&" left right -> conjuncts left ++ conjuncts right
  other -> [other]

-- | A record's rules, in declaration order, or why they cannot be named.
recordRules :: DataTypeDeclaration -> Either String [Rule]
recordRules declaration = do
  fields <- case dataTypeConstructors declaration of
    [constructor] | dataConstructorName constructor == dataTypeName declaration -> Right (dataConstructorFields constructor)
    _ -> Left (dataTypeName declaration ++ " is not a record")
  rules <- fmap concat $ forM fields $ \(label, ty) ->
    forM (concatMap conjuncts (typePredicates (Var label) ty)) $ \conjunct -> case conjunct of
      Apply (Var marker) predicate
        | Just name <- stripPrefix recordRulePrefix marker ->
            Right (Rule name Nothing "record" ("the rule " ++ name ++ " must hold") predicate)
        | Just name <- stripPrefix ruleLabelPrefix marker ->
            let (kind, message) = fromMaybe ("predicate", "must satisfy " ++ name) (described label ty predicate)
            in Right (Rule (label ++ "." ++ name) (Just label) (kindOf kind) (label ++ " " ++ message) predicate)
      predicate -> case described label ty predicate of
        Just (suffix, message) -> Right (Rule (label ++ "." ++ suffix) (Just label) (kindOf suffix) (label ++ " " ++ message) predicate)
        Nothing -> Left (dataTypeName declaration ++ ": the restriction " ++ prettyExpr predicate ++ " of " ++ label ++
          " has no name of its own; name the rule by writing `as <name>` after it")
  let ids = map ruleId rules
  forM_ ids $ \identity -> when (length (filter (== identity) ids) > 1)
    (Left (dataTypeName declaration ++ ": two rules are both " ++ identity ++ "; name one of them by writing `as <name>` after it"))
  pure rules
  where
    kindOf suffix = if suffix `elem` ["min", "max", "equals", "notEquals", "pattern", "oneOf", "length", "minLength", "maxLength", "items"] ++ formatNames
      then suffix else "predicate"

-- | A restriction's default suffix and its message, from its shape.
described :: String -> Type -> Expr -> Maybe (String, String)
described label ty predicate = case predicate of
  Binary op left right
    | subject left -> comparison op (prettyExpr right)
    | subject right -> comparison (mirrored op) (prettyExpr left)
    | lengthOf left -> measured op (prettyExpr right)
    | lengthOf right -> measured (mirrored op) (prettyExpr left)
  Apply (Apply (Var "prelude.regexMatches") pattern) value | subject value, StringLit text <- unlocated pattern ->
    Just (case [name | name <- formatNames, formatPattern name == Just text] of
      name : _ -> (name, "must be " ++ formatDescription name)
      [] -> ("pattern", "must match the regex " ++ show text))
  Apply (Apply (Var "prelude.member") value) items | subject value -> Just ("oneOf", "must be one of " ++ prettyExpr items)
  AllElementsExpr value _ _ | subject value -> Just ("items", "must hold only items that meet its restriction")
  AllPayloadsExpr value _ | subject value -> Just ("payload", "must hold only a value that meets its restriction")
  _ -> case spine predicate of
    Var name : arguments | any subject arguments, not ("prelude." `isPrefixOf` name), ':' `notElem` name ->
      let base = reverse (takeWhile (/= '.') (reverse name)) in Just (base, "must satisfy " ++ base)
    _ -> Nothing
  where
    subject value = unlocated value == Var label
    lengthOf value = case unlocated value of
      Apply function argument -> unlocated function == Var "prelude.length" && subject argument
      _ -> False
    spine expression = case unlocated expression of
      Apply function argument -> spine function ++ [argument]
      other -> [other]
    mirrored op = fromMaybe op (lookup op [("<", ">"), ("<=", ">="), (">", "<"), (">=", "<=")])
    comparison op bound = lookup op
      [ (">=", ("min", "must be at least " ++ bound)), (">", ("min", "must be greater than " ++ bound))
      , ("<=", ("max", "must be at most " ++ bound)), ("<", ("max", "must be less than " ++ bound))
      , ("==", ("equals", "must be " ++ bound)), ("!=", ("notEquals", "must not be " ++ bound)) ]
    measure = if baseType ty == Named "Text" then " characters" else " items"
    measured op bound = lookup op
      [ (">=", ("minLength", "must have at least " ++ bound ++ measure)), (">", ("minLength", "must have more than " ++ bound ++ measure))
      , ("<=", ("maxLength", "must have at most " ++ bound ++ measure)), ("<", ("maxLength", "must have fewer than " ++ bound ++ measure))
      , ("==", ("length", "must have exactly " ++ bound ++ measure)) ]

-- | A record's fields without the carriers of its labels and rule clauses:
-- the type every later stage sees.
plainDeclaration :: DataTypeDeclaration -> DataTypeDeclaration
plainDeclaration declaration = declaration { dataTypeConstructors =
  [constructor { dataConstructorFields = [(label, plainType ty) | (label, ty) <- dataConstructorFields constructor] }
  | constructor <- dataTypeConstructors declaration] }
  where
    plainType ty = case ty of
      Refined binder inner predicate -> Refined binder (plainType inner) (plain <$> predicate)
      other -> other
    plain expression = case expression of
      Located range inner -> Located range (plain inner)
      Binary "&&" left right -> Binary "&&" (plain left) (plain right)
      Apply (Var marker) inner | ruleLabelPrefix `isPrefixOf` marker || recordRulePrefix `isPrefixOf` marker -> plain inner
      other -> other

-- | Calls of the unit's own definitions replaced by their bodies, as a
-- field's restriction is where a value is built (LawSpec.Data), so the
-- totality audit sees the validator's conditions as the record's own.
unfolded :: M.Map String FunctionDefinition -> Expr -> Expr
unfolded definitions = go (3 :: Int)
  where
    go depth expression = case expression of
      Located range inner -> Located range (go depth inner)
      Binary op left right -> Binary op (go depth left) (go depth right)
      Unary op inner -> Unary op (go depth inner)
      ListLit items -> ListLit (map (go depth) items)
      ConstructLit name fields -> ConstructLit name (map (go depth) fields)
      AllElementsExpr value binder predicate -> AllElementsExpr (go depth value) binder (go depth predicate)
      Apply _ _ -> case spine expression of
        Var name : arguments
          | depth > 0, Just definition <- M.lookup name definitions
          , length arguments == length (functionArguments definition)
          , name `notElem` exprVars (functionBody definition) ->
              go (depth - 1) (replaceExprVars (zip (map fst (functionArguments definition)) (map (go depth) arguments)) (functionBody definition))
        function : arguments -> foldl Apply (go depth function) (map (go depth) arguments)
        [] -> expression
      other -> other
    spine expression = case expression of
      Apply function argument -> spine function ++ [argument]
      Located _ inner -> spine inner
      other -> [other]

-- Expression builders, in the shapes the parser gives the same source.
select :: Expr -> Expr -> Expr -> Expr
select condition yes no = foldl Apply (Var "prelude.select") [condition, yes, no]

access :: String -> Expr -> Expr
access label record = Apply (Var (fieldAccessPrefix ++ label)) record

updated :: Expr -> String -> Expr -> Expr
updated record label value = Apply (Apply (Var (fieldUpdatePrefix ++ label)) record) value

bound :: String -> Expr -> Expr -> Expr
bound name value body = MatchExpr value [MatchBranch letTag [name] body]

call :: String -> [Expr] -> Expr
call name = foldl Apply (Var name)

joined :: [Expr] -> Expr
joined pieces = case pieces of
  [] -> StringLit ""
  _ -> foldr1 (\piece rest -> call "prelude.append" [piece, rest]) pieces

containsText :: Expr -> Expr -> Expr
containsText text part = call "prelude.contains" [text, part]

-- | Adds what the unit's records ask for. A failure names the record.
elaborateContracts :: [String] -> Unit -> Either (Maybe Location, String) Unit
elaborateContracts demand unit = do
  let maskings = maskingDeclarations unit
      declared name = [declaration | declaration <- dataTypes unit, dataTypeName declaration == name]
      definitions = M.fromList [(functionName definition, definition) | definition <- functionDefinitions unit]
      taken = map dataTypeName (dataTypes unit) ++ map fst (functions unit) ++ M.keys definitions
  forM_ maskings $ \masking -> do
    let failed message = Left (Just (spanStart (maskingSpan masking)), "masking " ++ maskingRecord masking ++ ": " ++ message)
    when (null (declared (maskingRecord masking))) (failed "this unit declares no such record")
    when (length [() | other <- maskings, maskingRecord other == maskingRecord masking] > 1) (failed "the record has more than one masking block")
    let labels = [label | (label, _) <- maskingFields masking]
    unless (length labels == length (nub labels)) (failed "a field is masked twice")
  contracts <- fmap concat $ forM (dataTypes unit) $ \declaration -> do
    let record = dataTypeName declaration
        at = Just (spanStart (dataTypeSpan declaration))
        failed message = Left (at, message)
        masks = concat [[(label, mask) | (label, mask) <- maskingFields masking] | masking <- maskings, maskingRecord masking == record]
        asked = not (null masks) || any (`elem` demand) (contractNames record)
        marked = any (`isInfixOf` show declaration) [ruleLabelPrefix, recordRulePrefix]
        isRecord = case dataTypeConstructors declaration of
          [constructor] -> dataConstructorName constructor == record && null (dataConstructorEquations constructor)
          _ -> False
        own = [name | name <- contractNames record, name `elem` taken]
    if not (asked || marked) || not isRecord then
      if null masks then pure [] else failed ("masking " ++ record ++ ": only a record has fields to mask")
    -- A unit that declares one of the names itself (a workflow step called
    -- validateOrder, say) asked for nothing: its record is left as it is,
    -- whatever its restrictions look like.
    else if null masks && not marked && not (null own) then pure []
    else do
      rules <- either failed Right (recordRules declaration)
      let summary generated = RecordContract record
            [ContractRule (ruleId rule) (ruleField rule) (ruleKind rule) (ruleMessage rule) | rule <- rules] masks generated
      -- A unit that declares one of the names itself keeps it.
      if not asked || (null masks && not (null own)) then pure [(summary False, Nothing)] else do
        forM_ (take 1 own) $ \name ->
          failed ("masking " ++ record ++ ": the unit already declares " ++ name ++ ", which masking generates")
        unless (null (dataTypeParameters declaration))
          (failed (record ++ " has type parameters; a validator is generated for a record without them"))
        generated <- either failed Right (generate unit definitions declaration rules masks)
        pure [(summary True, Just generated)]
  let additions = [generated | (_, Just generated) <- contracts]
      plain = unit { dataTypes = map plainDeclaration (dataTypes unit) }
      leftover = [prefix | prefix <- [ruleLabelPrefix, recordRulePrefix], prefix `isInfixOf` show (dataTypes plain)]
  unless (null leftover)
    (Left (Nothing, "`as <name>` names one whole restriction of a record's field: write it after a restriction that `and` joins to the others, outside any parentheses"))
  let newDefinitions = concat [definitions' | Generated _ definitions' _ <- additions]
      signature definition = (functionName definition, foldr Arrow (functionResult definition) (map snd (functionArguments definition)))
  pure plain
    { dataTypes = dataTypes plain ++ concat [types | Generated types _ _ <- additions]
    , functions = functions plain ++ map signature newDefinitions
    , functionDefinitions = functionDefinitions plain ++ newDefinitions
    , declarationSpans = declarationSpans plain ++ [(functionName definition, functionSpan definition) | definition <- newDefinitions]
    , laws = laws plain ++ concat [laws' | Generated _ _ laws' <- additions]
    , recordContracts = map fst contracts
    }

-- | What one record adds to its unit.
data Generated = Generated [DataTypeDeclaration] [FunctionDefinition] [Law]

generate :: Unit -> M.Map String FunctionDefinition -> DataTypeDeclaration -> [Rule] -> [(String, FieldMask)] -> Either String Generated
generate unit definitions declaration rules masks = do
  forM_ fields $ \(label, ty) -> when (named ty)
    (Left (validatorName record ++ ": the field " ++ label ++ " has a named refinement, which is not validated yet; write its restriction in the record"))
  forM_ masks $ \(label, mask) -> do
    ty <- maybe (Left ("masking " ++ record ++ ": the record has no field " ++ label)) Right (lookup label drafted)
    case mask of
      MaskHash -> Left ("masking " ++ record ++ ": `hash` is not generated on any target yet: it is a keyed BLAKE3 digest whose key the host application supplies, and no runtime has it. Show " ++ label ++ " as hidden or last <n> until one does")
      MaskLast count | count < 1 -> Left ("masking " ++ record ++ ": last " ++ show count ++ " shows nothing; write hidden")
      _ | mask /= MaskHidden && ty /= Named "Text" -> Left ("masking " ++ record ++ ": " ++ label ++ " is not a Text, so it can only be shown as hidden")
      _ -> Right ()
  forM_ [rule | rule <- rules, ruleField rule == Nothing] $ \rule ->
    unless (exemplified (ruleId rule))
      (Left (record ++ ": the rule " ++ ruleId rule ++ " is of the whole record, so no draft that breaks it alone can be generated; give an example that ends `fails with " ++ ruleId rule ++ "`"))
  pure (Generated [draftType] ([draftOf, violations, validator] ++ renderers) (passes : isolating ++ hiding))
  where
    record = dataTypeName declaration
    range = dataTypeSpan declaration
    Span start _ = range
    fields = concat [dataConstructorFields constructor | constructor <- dataTypeConstructors declaration]
    drafted = [(label, baseType ty) | (label, ty) <- fields]
    labels = map fst fields
    named ty = "RefinementApp" `isInfixOf` show ty
    draftType = DataTypeDeclaration (draftName record) [] [ConstructorDeclaration (draftName record) drafted range []] range Nothing
    violationType = Applied "List" (Named "Violation")
    -- Names no field has.
    fresh base = head [candidate | suffix <- [0 :: Int ..], let candidate = base ++ replicate suffix '_', candidate `notElem` labels]
    draft = fresh "draft"
    value = fresh "value"
    -- The body, with each field name it reads bound to the draft's value.
    withFields subject body = foldr (\label rest -> bound label (access label (Var subject)) rest) body
      [label | label <- labels, label `elem` exprVars body]
    draftOf = FunctionDefinition (draftOfName record) [(value, Named record)] (Named (draftName record)) []
      (ConstructLit (draftName record) [access label (Var value) | label <- labels]) range
    maskOf label = lookup label masks
    -- A field's value as a person may read it, where it has a text form.
    shown label ty = case maskOf label of
      Just MaskHidden -> Just (StringLit "***")
      Just MaskEmail -> Just (call "prelude.maskEmail" [Var label])
      Just (MaskLast count) -> Just (call "prelude.maskLast" [Number count, Var label])
      Just MaskHash -> Nothing
      Nothing -> case ty of
        Named "Text" -> Just (Var label)
        Named "Bool" -> Just (select (Var label) (StringLit "true") (StringLit "false"))
        Named name | isInteger name -> Just (call "prelude.textOf" [Var label])
                   | name `elem` [maskingRecord masking | masking <- maskingDeclarations unit] -> Just (call (maskedName name) [Var label])
        _ -> Nothing
    violation rule = ConstructLit "Violation"
      [ StringLit (ruleId rule)
      , maybe (ConstructLit "Absent" []) (\label -> ConstructLit "Present" [StringLit label]) (ruleField rule)
      , case ruleField rule >>= \label -> lookup label drafted >>= shown label of
          Just text -> joined [StringLit (ruleMessage rule ++ ", but was "), text]
          Nothing -> StringLit (ruleMessage rule) ]
    -- From the last rule to the first: the violations after a rule, then the
    -- rule's own before them when it is broken.
    violations = FunctionDefinition (violationsName record) [(draft, Named (draftName record))] violationType []
      (withFields draft (foldr (\(index, rule) rest ->
          let after = fresh ("rest" ++ show index)
          in bound after rest (select (rulePredicate rule) (Var after) (ConstructLit "Cons" [violation rule, Var after])))
        (ConstructLit "Nil" []) (zip [1 :: Int ..] rules))) range
    validator = FunctionDefinition (validatorName record) [(draft, Named (draftName record))]
      (Application "Either" [violationType, Named record]) []
      (withFields draft (foldr (\rule rest -> select (unfolded definitions (rulePredicate rule)) rest
          (ConstructLit "Left" [call (violationsName record) [Var draft]]))
        (ConstructLit "Right" [ConstructLit record (map Var labels)]) rules)) range
    law title description proposition = Law (record ++ " " ++ title) [] [] proposition description
      "LawSpec generates the validator; this law checks every target runs it as specified" [] [] start [] emptyLawMetadata
    passes = law "passes its own validator" ("every " ++ record ++ " is what " ++ validatorName record ++ " gives for its draft")
      (Forall [(value, Named record)] (Equal (call (validatorName record) [call (draftOfName record) [Var value]]) (ConstructLit "Right" [Var value])))
    -- Whether the unit already says, by an example, what a rule's failure is.
    exemplified identity = ("Apply (Apply (Var \"prelude.failsWithRule\") (StringLit " ++ show identity ++ "))") `isInfixOf` show (laws unit)
    -- For a field rule: a valid record, and another value for the field that
    -- breaks this rule and no other rule that reads the field.
    isolating =
      [ law ("reports " ++ ruleId rule ++ " alone") ("a draft that breaks only " ++ ruleId rule ++ " fails with it and nothing else")
          (Forall [(value, Named record), (candidate, ty)]
            (Implies (foldr1 (Binary "&&") (Unary "!" (moved (rulePredicate rule)) : map (moved . rulePredicate) others))
              (Equal (call "prelude.violatedRules" [call (violationsName record) [updated (call (draftOfName record) [Var value]) label (Var candidate)]])
                (ListLit [StringLit (ruleId rule)]))))
      | rule <- rules, Just label <- [ruleField rule], Just ty <- [lookup label drafted], not (exemplified (ruleId rule))
      , let candidate = fresh "candidate"
            moved = replaceExprVars ((label, Var candidate) : [(other, access other (Var value)) | other <- labels, other /= label])
            others = [other | other <- rules, ruleId other /= ruleId rule, label `elem` exprVars (rulePredicate other)] ]
    rendering subject = withFields subject (joined ([StringLit (record ++ "{")] ++
      concat [[StringLit ((if index > 0 then ", " else "") ++ label ++ "="), fromMaybe (StringLit "_") (shown label ty)]
             | (index, (label, ty)) <- zip [0 :: Int ..] drafted] ++ [StringLit "}"]))
    renderers = if null masks then [] else
      [ FunctionDefinition (maskedDraftName record) [(draft, Named (draftName record))] (Named "Text") [] (rendering draft) range
      , FunctionDefinition (maskedName record) [(value, Named record)] (Named "Text") []
          (call (maskedDraftName record) [call (draftOfName record) [Var value]]) range ]
    hiding =
      [ case (mask, ty) of
          (MaskHidden, other) | other /= Named "Text" ->
            law ("hides " ++ label) ("the rendering of a " ++ record ++ " does not depend on " ++ label)
              (Forall [(draft, Named (draftName record)), (another, Named (draftName record))]
                (Equal (call (maskedDraftName record) [updated (Var draft) label (access label (Var another))]) (call (maskedDraftName record) [Var draft])))
          _ ->
            let secret = case mask of
                  MaskLast count -> joined [StringLit maskSentinel, Var filler, StringLit (replicate (fromInteger count) '0')]
                  MaskEmail -> joined [StringLit ("a" ++ maskSentinel), Var filler, StringLit "@example.org"]
                  _ -> joined [Var filler, StringLit maskSentinel, Var filler]
                changed = updated (Var draft) label secret
            in law ("masks " ++ label) ("what the mask of " ++ label ++ " hides shows in no rendering of a " ++ record ++ " and in no violation message")
              (Forall [(draft, Named (draftName record)), (filler, Named "Text")]
                (Implies (Unary "!" (containsText (call (maskedDraftName record) [Var draft]) (StringLit maskSentinel)))
                  (Holds (Binary "&&" (Unary "!" (containsText (call (maskedDraftName record) [changed]) (StringLit maskSentinel)))
                    (call "prelude.messagesHide" [StringLit maskSentinel, call (violationsName record) [changed]])))))
      | (label, mask) <- masks, Just ty <- [lookup label drafted]
      , let another = fresh "another"
            filler = fresh "filler" ]
