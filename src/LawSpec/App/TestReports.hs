-- | What a native test runner reported, ported from the Node CLI's
-- test-command.mjs: JUnit XML (read element by element, as its regular
-- expressions read it), Go's test2json events, Rust's and hspec's printed
-- lines, and the Node, BEAM and Swift event files LawSpec's own reporters
-- write; the merged JUnit report of @--report junit=<path>@, and the JUnit
-- a runner that writes none is given. Everything here is pure: the caller
-- reads the files ("LawSpec.App.Test").
--
-- A test is a JSON object, as test-command.mjs builds it, since the results
-- file records it as it is: @{name, classname, status, time?, failure?,
-- reason?}@, or the event row itself for the event reports.
-- ref:DEC-haskell-application-port ref:DEC-s1j-shared-failures
module LawSpec.App.TestReports
  ( Element (..),
    junitElements,
    attributeMatches,
    attributes,
    junitTests,
    goJsonTests,
    rustTests,
    hspecTests,
    nodeEventTests,
    beamEventTests,
    swiftEventTests,
    SwiftGroup (..),
    mergeJunit,
    junitFromTests,
    escapeXml,
    unescapeXml,
    jsSpace,
    jsTrim,
    lineTerminator,
    toFixed,
    jsNumber,
    finiteNumber,
  )
where

import Data.Char (isAsciiLower, isAsciiUpper, isDigit)
import Data.List (isPrefixOf, isSuffixOf, nub)
import qualified Data.Map.Strict as M
import Data.Maybe (fromMaybe, isJust, mapMaybe)
import Data.Scientific (fromFloatDigits, toRealFloat)
import LawSpec.App.Arguments (javascriptNumber)
import LawSpec.App.Json

-- | One complete outer element: its name, where it starts, its opening tag
-- and its whole text.
data Element = Element
  { elementName :: String,
    elementOpening :: String,
    elementXml :: String
  }
  deriving (Eq, Show)

-- | A match of junitElements' tag expression: where it starts, the text from
-- there on, its length, and for a start or end tag whether it closes and its
-- name (comments, CDATA sections and processing instructions have none).
data Tag = Tag Int String Int (Maybe (Bool, String))

-- | JavaScript's \s.
jsSpace :: Char -> Bool
jsSpace c = c `elem` ("\t\n\v\f\r \x00A0\x1680\x2028\x2029\x202F\x205F\x3000\xFEFF" :: String) || (c >= '\x2000' && c <= '\x200A')

-- | The characters JavaScript's . does not match.
lineTerminator :: Char -> Bool
lineTerminator c = c `elem` ("\n\r\x2028\x2029" :: String)

-- | String.prototype.trim.
jsTrim :: String -> String
jsTrim = reverse . dropWhile jsSpace . reverse . dropWhile jsSpace

-- | \w without the u flag.
wordChar :: Char -> Bool
wordChar c = isAsciiLower c || isAsciiUpper c || isDigit c || c == '_'

nameStart :: Char -> Bool
nameStart c = isAsciiLower c || isAsciiUpper c || c == '_'

nameChar :: Char -> Bool
nameChar c = wordChar c || c `elem` (":.-" :: String)

-- | The index of the first occurrence of a needle, if any.
findText :: String -> String -> Maybe Int
findText needle = go 0
  where
    go _ [] = Nothing
    go n haystack@(_ : rest)
      | needle `isPrefixOf` haystack = Just n
      | otherwise = go (n + 1) rest

-- | Every match of
-- @<!--[\s\S]*?-->|<!\[CDATA\[[\s\S]*?\]\]>|<\?[\s\S]*?\?>|<(\/?)([A-Za-z_][\w:.-]*)(?:[^"'<>]|"[^"]*"|'[^']*')*>@,
-- left to right, as matchAll finds them.
scanTags :: String -> [Tag]
scanTags = go 0
  where
    go _ [] = []
    go i text@('<' : rest) = case tagAt text of
      Just (len, info) -> Tag i text len info : go (i + len) (drop len text)
      Nothing -> go (i + 1) rest
    go i (_ : rest) = go (i + 1) rest
    tagAt text =
      firstJust
        [ delimited "<!--" "-->" text,
          delimited "<![CDATA[" "]]>" text,
          delimited "<?" "?>" text,
          element text
        ]
    firstJust = foldr (\candidate kept -> maybe kept Just candidate) Nothing
    delimited open close text
      | open `isPrefixOf` text = (\k -> (length open + k + length close, Nothing)) <$> findText close (drop (length open) text)
      | otherwise = Nothing
    element text = case text of
      '<' : afterOpen ->
        let (closing, afterSlash) = case afterOpen of
              '/' : more -> (True, more)
              _ -> (False, afterOpen)
         in case afterSlash of
              c : more
                | nameStart c ->
                    let name = c : takeWhile nameChar more
                        afterName = drop (length name) afterSlash
                        consumed = 1 + (if closing then 1 else 0) + length name
                     in (\len -> (consumed + len, Just (closing, name))) <$> body 0 afterName
              _ -> Nothing
      _ -> Nothing
    body n s = case s of
      '>' : _ -> Just (n + 1)
      '"' : r -> quoted '"' n r
      '\'' : r -> quoted '\'' n r
      '<' : _ -> Nothing
      _ : r -> body (n + 1) r
      [] -> Nothing
    quoted q n r = case break (== q) r of
      (inside, _ : after) -> body (n + 2 + length inside) after
      _ -> Nothing

-- | junitElements(xml, names): the complete outer elements with those
-- names, nested suites and native payloads kept whole. Comments and CDATA
-- are never elements.
junitElements :: String -> [String] -> [Element]
junitElements xml names = go Nothing (scanTags xml)
  where
    go _ [] = []
    go current (Tag index suffix len info : rest) = case info of
      Just (closing, name)
        | name `elem` names -> case current of
            Nothing
              | closing -> go Nothing rest
              | otherwise -> advance (Open name index suffix tagText 0) closing name
            Just open -> advance open closing name
      _ -> go current rest
      where
        tagText = take len suffix
        advance open closing name
          | name /= openName open = go (Just open) rest
          | depth' == 0 = Element (openName open) (openTag open) (take (index + len - openStart open) (openText open)) : go Nothing rest
          | otherwise = go (Just open {openDepth = depth'}) rest
          where
            depth' = openDepth open + (if closing then -1 else if emptyTag tagText then 0 else 1)
    -- /\/\s*>$/
    emptyTag tag = case reverse tag of
      '>' : before -> take 1 (dropWhile jsSpace before) == "/"
      _ -> False

-- | The element junitElements is inside: its name, where it starts, the
-- text from there, its opening tag and its depth.
data Open = Open {openName :: String, openStart :: Int, openText :: String, openTag :: String, openDepth :: Int}

-- | The matches of @\s([A-Za-z_:][\w:.-]*)\s*=\s*(?:"([^"]*)"|'([^']*)')@ in
-- an opening tag: where each starts, its length, the name and the raw value.
attributeMatches :: String -> [(Int, Int, String, String)]
attributeMatches = go 0
  where
    go _ [] = []
    go i (c : rest)
      | jsSpace c, Just (len, name, value) <- attributeAt rest = (i, 1 + len, name, value) : go (i + 1 + len) (drop len rest)
      | otherwise = go (i + 1) rest
    attributeAt text = case text of
      c : more
        | nameStart c || c == ':' ->
            let name = c : takeWhile nameChar more
                afterName = drop (length name) text
                (spaces, afterSpaces) = span jsSpace afterName
             in case afterSpaces of
                  '=' : afterEquals ->
                    let (spaces', value) = span jsSpace afterEquals
                     in case value of
                          q : inside
                            | q `elem` ("\"'" :: String),
                              (content, _ : _) <- break (== q) inside ->
                                Just (length name + length spaces + 1 + length spaces' + length content + 2, name, content)
                          _ -> Nothing
                  _ -> Nothing
      _ -> Nothing

-- | Object.fromEntries of the matches: each attribute's last value.
attributes :: String -> M.Map String String
attributes opening = M.fromList [(name, value) | (_, _, name, value) <- attributeMatches opening]

unescapeXml :: String -> String
unescapeXml =
  replace "&amp;" "&"
    . replace "&#39;" "'"
    . replace "&apos;" "'"
    . replace "&quot;" "\""
    . replace "&gt;" ">"
    . replace "&lt;" "<"

escapeXml :: String -> String
escapeXml = concatMap $ \case
  '&' -> "&amp;"
  '<' -> "&lt;"
  '>' -> "&gt;"
  '"' -> "&quot;"
  c -> [c]

-- | String.prototype.replaceAll with a string pattern.
replace :: String -> String -> String -> String
replace needle replacement = go
  where
    go [] = []
    go text@(c : rest)
      | needle `isPrefixOf` text = replacement ++ go (drop (length needle) text)
      | otherwise = c : go rest

-- | Number(text), as a JSON number; 'Nothing' for NaN and the infinities.
jsNumber :: String -> Maybe Json
jsNumber text = (\r -> JNumber (fromFloatDigits (fromRational r :: Double))) <$> javascriptNumber text

-- | A JSON number that is finite and not negative (Number.isFinite(x) &&
-- x >= 0); strings and other values are not numbers.
finiteNumber :: Maybe Json -> Maybe Json
finiteNumber = \case
  Just value@(JNumber n) | toRealFloat n >= (0 :: Double), not (isInfinite (toRealFloat n :: Double)) -> Just value
  _ -> Nothing

-- | The tests in one runner's JUnit XML files, in order.
junitTests :: [String] -> [Json]
junitTests = concatMap fileTests
  where
    fileTests xml = map testOf (junitElements xml ["testcase"])
    testOf element =
      let values = M.map unescapeXml (attributes (elementOpening element))
          native = junitElements (elementXml element) ["failure", "error", "skipped"]
          failure = filter ((/= "skipped") . elementName) native
          incomplete =
            any
              ( \property ->
                  let value = M.map unescapeXml (attributes (elementOpening property))
                   in M.lookup "name" value == Just "lawspec.status" && M.lookup "value" value == Just "incomplete"
              )
              (junitElements (elementXml element) ["property"])
          status
            | incomplete = "incomplete"
            | not (null failure) = "failed"
            | not (null native) = "skipped"
            | otherwise = "passed"
          time = M.lookup "time" values >>= jsNumber
       in jsObject
            ( [ ("name", JString (dropCall (fromMaybe "" (M.lookup "name" values)))),
                ("classname", JString (fromMaybe "" (M.lookup "classname" values))),
                ("status", JString status)
              ]
                ++ [("time", t) | Just t <- [finiteNumber time]]
                ++ ( if not (null failure)
                       then [("failure", JString (joinLines (map detail failure)))]
                       else [("reason", JString (joinLines (map detail native))) | status == "skipped"]
                   )
            )
    dropCall name = if "()" `isSuffixOf` name then take (length name - 2) name else name
    joinLines = foldr1' (\a b -> a ++ "\n" ++ b)
    foldr1' _ [] = ""
    foldr1' f items = foldr1 f items
    detail element =
      let message = M.lookup "message" (M.map unescapeXml (attributes (elementOpening element)))
          content = unescapeXml (unwrapCdata (dropClosing (drop (length (elementOpening element)) (elementXml element))))
       in joinLines (filter (not . null) (maybe [] pure message ++ [content]))
    -- .replace(/<\/(failure|error|skipped)>\s*$/, '')
    dropClosing text =
      let trimmed = reverse (dropWhile jsSpace (reverse text))
          closing = [tag | name <- ["failure", "error", "skipped"], let tag = "</" ++ name ++ ">", tag `isSuffixOf` trimmed]
       in case closing of
            tag : _ -> take (length trimmed - length tag) trimmed
            [] -> text
    -- .replace(/<!\[CDATA\[([\s\S]*?)\]\]>/g, (_, text) => text)
    unwrapCdata text = case findText "<![CDATA[" text of
      Nothing -> text
      Just at ->
        let after = drop (at + 9) text
         in case findText "]]>" after of
              Nothing -> text
              Just end -> take at text ++ take end after ++ unwrapCdata (drop (end + 3) after)

-- | go test -json: each pass or fail event of a test.
goJsonTests :: String -> [Json]
goJsonTests output = mapMaybe testOf (splitLines output)
  where
    testOf line = case parseJson line of
      Right event@(JObject _)
        | Just (JString action) <- member "Action" event,
          action `elem` ["pass", "fail"],
          Just test <- member "Test" event,
          isTruthy test ->
            Just . jsObject $
              [("name", test)]
                ++ [("classname", package) | Just package <- [member "Package" event]]
                ++ [("status", JString (if action == "pass" then "passed" else "failed"))]
                ++ [("time", t) | Just t <- [finiteNumber (member "Elapsed" event)]]
      _ -> Nothing

-- | output.split('\n').
splitLines :: String -> [String]
splitLines text = case break (== '\n') text of
  (line, []) -> [line]
  (line, _ : rest) -> line : splitLines rest

-- | cargo test's lines, /^test (\S+) \.\.\. (ok|FAILED|ignored)/, ignored
-- tests left out.
rustTests :: String -> [Json]
rustTests output = mapMaybe testOf (splitLines output)
  where
    testOf line = case stripPrefix' "test " line of
      Just rest@(c : _)
        | not (jsSpace c) ->
            let name = takeWhile (not . jsSpace) rest
             in case stripPrefix' " ... " (drop (length name) rest) of
                  Just verdict
                    | "ok" `isPrefixOf` verdict -> Just (test name "passed")
                    | "FAILED" `isPrefixOf` verdict -> Just (test name "failed")
                  _ -> Nothing
      _ -> Nothing
    test name status = JObject [("name", JString name), ("classname", JString ""), ("status", JString status)]

stripPrefix' :: String -> String -> Maybe String
stripPrefix' prefix text = if prefix `isPrefixOf` text then Just (drop (length prefix) text) else Nothing

-- | hspec's printed tree: each module, then its examples beneath it.
hspecTests :: String -> [Json]
hspecTests output = go "" (splitLines output)
  where
    go _ [] = []
    go module' (line : rest) =
      let module'' = case line of
            c : _ | not (jsSpace c), not (summaryLine line) -> jsTrim line
            _ -> module'
       in case example line of
            Just (name, mark) ->
              JObject [("name", JString name), ("classname", JString module''), ("status", JString (if mark == '\x2714' then "passed" else "failed"))]
                : go module'' rest
            Nothing -> go module'' rest
    -- /^(Finished|Failures|Randomized|\d+ examples?)/
    summaryLine line =
      any (`isPrefixOf` line) ["Finished", "Failures", "Randomized"]
        || case span isDigit line of
          (_ : _, rest) -> " example" `isPrefixOf` rest
          _ -> False
    example line = case span jsSpace line of
      (_ : _, rest) -> lawExample rest `orElse` modelExample rest
      _ -> Nothing
    orElse (Just a) _ = Just a
    orElse Nothing b = b
    -- (law\S*?):?(?:\s.*)?\s\[([✔✘])\]\s*$, the lazy name as short as
    -- the rest allows.
    lawExample rest = case stripPrefix' "law" rest of
      Nothing -> Nothing
      Just afterLaw ->
        let run = takeWhile (not . jsSpace) afterLaw
         in firstOf
              [ (\mark -> ("law" ++ take k afterLaw, mark)) <$> lawRest (drop k afterLaw)
              | k <- [0 .. length run]
              ]
    lawRest text = firstOf ([afterColon t | Just t <- [stripPrefix' ":" text]] ++ [afterColon text])
    afterColon text =
      firstOf
        ( [ ending suffix
          | c : more <- [text],
            jsSpace c,
            suffix <- reverse (tailsWithin more)
          ]
            ++ [ending text]
        )
    -- The suffixes .* can leave: as far as the first line terminator.
    tailsWithin text =
      text : case text of
        c : more | not (lineTerminator c) -> tailsWithin more
        _ -> []
    -- \s\[([✔✘])\]\s*$
    ending text = case text of
      c : '[' : mark : ']' : rest
        | jsSpace c,
          mark `elem` ("\x2714\x2718" :: String),
          all jsSpace rest ->
            Just mark
      _ -> Nothing
    -- (model .+?|supervision)\s\[([✔✘])\]\s*$
    modelExample rest =
      case stripPrefix' "model " rest of
        Just afterModel ->
          firstOf
            [ (\mark -> ("model " ++ take k afterModel, mark)) <$> ending (drop k afterModel)
            | k <- [1 .. length (takeWhile (not . lineTerminator) afterModel)]
            ]
            `orElse` supervision rest
        Nothing -> supervision rest
    supervision rest = (\mark -> ("supervision", mark)) <$> (stripPrefix' "supervision" rest >>= ending)
    firstOf = foldr (\candidate kept -> maybe kept Just candidate) Nothing

-- | raw.trim().split('\n').map(JSON.parse), or 'Nothing' when any line is
-- not JSON.
jsonLines :: String -> Maybe [Json]
jsonLines raw = mapM (either (const Nothing) Just . parseJson) (splitLines (jsTrim raw))

-- | A report's first row, the rows between, and its last row.
ends :: [a] -> Maybe (a, [a], a)
ends = \case
  first : rest@(_ : _) -> Just (first, init rest, last rest)
  _ -> Nothing

isString :: Maybe Json -> Bool
isString = \case
  Just (JString _) -> True
  _ -> False

-- | LawSpec's Node reporter (node-events-reporter.mjs): the rows of a sealed
-- report of this invocation, or none when it is missing, stale, malformed
-- or interrupted.
nodeEventTests :: String -> String -> [Json]
nodeEventTests run raw = case jsonLines raw of
  Just rows
    | length rows >= 2,
      Just (first, tests, final) <- ends rows,
      member "event" first == Just (JString "start"),
      member "event" final == Just (JString "end"),
      all (\row -> member "version" row == Just (integer 1) && member "run" row == Just (JString run)) rows,
      member "count" final == Just (integer (fromIntegral (length rows - 2))),
      all valid tests ->
        tests
  _ -> []
  where
    valid row =
      member "event" row == Just (JString "test")
        && isString (member "name" row)
        && isString (member "classname" row)
        && maybe False (`elem` map JString ["passed", "failed", "skipped"]) (member "status" row)
        && maybe True (isJust . finiteNumber . Just) (member "time" row)
        && maybe True (isString . Just) (member "failure" row)

-- | LawSpec's BEAM listener's report: the rows of a sealed report of this
-- invocation, or none.
beamEventTests :: String -> String -> [Json]
beamEventTests run raw = case jsonLines raw of
  Just rows
    | length rows >= 2,
      Just (first, tests, final) <- ends rows,
      member "event" first == Just (JString "start"),
      member "event" final == Just (JString "end"),
      all (\row -> member "run" row == Just (JString run)) rows,
      all valid tests ->
        tests
  _ -> []
  where
    valid row =
      member "event" row == Just (JString "test")
        && maybe False (`elem` map JString ["passed", "failed"]) (member "status" row)
        && isString (member "name" row)
        && isString (member "classname" row)
        && isString (member "identity" row)
        && isJust (finiteNumber (member "time" row))

-- | One ordered Swift group the report must account for.
data SwiftGroup = SwiftGroup
  { groupUnit :: Json,
    groupLaw :: Json,
    groupSuite :: String,
    groupMinimum :: Integer
  }
  deriving (Eq, Show)

-- | swiftExecutedTests: the JUnit tests Swift wrote, with each ordered
-- aggregate refined into its completed invocations by LawSpec's lifecycle
-- events, when they account for it exactly.
swiftEventTests :: [Json] -> String -> String -> [SwiftGroup] -> [Json]
swiftEventTests native run raw groups = case jsonLines raw of
  Just rows
    | not (null rows),
      all (\row -> isObject row && member "version" row == Just (integer 1) && member "run" row == Just (JString run)) rows,
      Just done <- foldl (\state row -> state >>= consume row) (Just (Swift [] [] [] M.empty)) rows >>= complete ->
        ordinary ++ done
  _ -> ordinary
  where
    ordinary = filter ((/= Just (JString "ordered(_:)")) . member "name") native
    isObject = \case
      JObject _ -> True
      _ -> False
    field name value = fromMaybe JNull (member name value)
    key unit name = compact (JArray [unit, name])
    expected = M.fromList [(key (groupUnit g) (groupLaw g), g) | g <- groups]
    -- new Map(...).values(): each key once, at its first place, last value.
    expectedGroups = [g | (k, _) <- firstPlaces, Just g <- [M.lookup k expected]]
    firstPlaces = foldl (\kept g -> let k = key (groupUnit g) (groupLaw g) in if any ((== k) . fst) kept then kept else kept ++ [(k, ())]) [] groups
    consume row state = case member "unit" row of
      Just unit@(JString _) -> case member "event" row of
        Just (JString "plan") -> case member "cases" row of
          Just (JArray planned@(_ : _)) -> case lookup unit (swiftPlans state) of
            Just previous
              | compact (JArray previous) /= compact (JArray planned) -> Nothing
              | otherwise -> Just state
            Nothing -> foldl (\acc item -> acc >>= addCase unit item) (Just state {swiftPlans = swiftPlans state ++ [(unit, planned)]}) planned
          _ -> Nothing
        Just (JString event)
          | event `elem` ["case-start", "case-end"] -> do
              let caseId = key unit (field "id" row)
              item <- lookup caseId (swiftCases state)
              if member "name" item /= member "name" row || member "law" item /= member "law" row
                then Nothing
                else
                  if event == "case-start"
                    then if caseId `elem` swiftStarts state then Nothing else Just state {swiftStarts = swiftStarts state ++ [caseId]}
                    else
                      if caseId `notElem` swiftStarts state
                        || M.member caseId (swiftEnds state)
                        || maybe True (`notElem` map JString ["passed", "failed"]) (member "status" row)
                        || not (isJust (finiteNumber (member "time" row)))
                        || maybe False (not . isString . Just) (member "failure" row)
                        then Nothing
                        else Just state {swiftEnds = M.insert caseId row (swiftEnds state)}
        _ -> Nothing
      _ -> Nothing
    addCase unit item state = case item of
      JObject _
        | Just (JString itemId@(_ : _)) <- member "id" item,
          Just (JString (_ : _)) <- member "name" item,
          Just law@(JString _) <- member "law" item,
          M.member (key unit law) expected,
          let caseId = key unit (JString itemId),
          caseId `notElem` map fst (swiftCases state) ->
            Just state {swiftCases = swiftCases state ++ [(caseId, setMember "unit" unit item)]}
      _ -> Nothing
    complete state
      | length (swiftCases state) /= length (swiftStarts state) || length (swiftCases state) /= M.size (swiftEnds state) = Nothing
      | otherwise = concat <$> mapM (completed state) expectedGroups
    completed state group = do
      let members' = [(caseId, item) | (caseId, item) <- swiftCases state, member "unit" item == Just (groupUnit group), member "law" item == Just (groupLaw group)]
      if fromIntegral (length members') < groupMinimum group
        then Nothing
        else do
          aggregate <- case [test | test <- native, member "name" test == Just (JString "ordered(_:)"), lastSegment (member "classname" test) == groupSuite group] of
            [one] | member "status" one `elem` map Just [JString "passed", JString "failed"] -> Just one
            _ -> Nothing
          let suiteFailed =
                or
                  [ member "status" ended == Just (JString "failed")
                  | (caseId, item) <- swiftCases state,
                    Just expectedGroup <- [M.lookup (key (field "unit" item) (field "law" item)) expected],
                    groupSuite expectedGroup == groupSuite group,
                    Just ended <- [M.lookup caseId (swiftEnds state)]
                  ]
              aggregatePassed = member "status" aggregate == Just (JString "passed")
              incomplete = not aggregatePassed && not suiteFailed
          if aggregatePassed && suiteFailed
            then Nothing
            else
              Just
                [ jsObject
                    ( [ ("name", field "id" item),
                        ("classname", field "classname" aggregate),
                        ("identity", JString (jsString (field "unit" item) ++ "::" ++ jsString (field "law" item))),
                        ("unit", field "unit" item),
                        ("nativeName", field "law" item),
                        ("status", if incomplete then JString "incomplete" else field "status" result),
                        ("time", field "time" result)
                      ]
                        ++ ( if incomplete
                               then [("failure", fromMaybe (JString "Swift aggregate failed outside its invocation bodies") (member "failure" aggregate))]
                               else [("failure", f) | Just f <- [member "failure" result]]
                           )
                    )
                | (caseId, item) <- members',
                  let result = fromMaybe JNull (M.lookup caseId (swiftEnds state))
                ]
    lastSegment = \case
      Just (JString text) -> reverse (takeWhile (/= '.') (reverse text))
      _ -> ""

-- | What the Swift lifecycle events have shown so far: each unit's plan,
-- the planned cases by id, the ids started and the rows that ended them.
data Swift = Swift
  { swiftPlans :: [(Json, [Json])],
    swiftCases :: [(String, Json)],
    swiftStarts :: [String],
    swiftEnds :: M.Map String Json
  }

-- | mergeJunit: every target's suites, renamed with the target, in one
-- @<testsuites>@ with the totals.
mergeJunit :: [(String, String)] -> String
mergeJunit reports =
  "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<testsuites tests=\""
    ++ show (total "tests")
    ++ "\" failures=\""
    ++ show (total "failures")
    ++ "\" errors=\""
    ++ show (total "errors")
    ++ "\" skipped=\""
    ++ show (total "skipped")
    ++ "\">\n"
    ++ joinWith "\n" (map snd suites)
    ++ "\n</testsuites>\n"
  where
    suites = concatMap suitesOf reports
    total key = sum [counted key suite | suite <- suites]
    suitesOf (target, xml) =
      let elements = junitElements xml ["testsuite", "testcase"]
          found = [(elementOpening e, elementXml e) | e <- elements, elementName e == "testsuite"]
          loose = [e | e <- elements, elementName e == "testcase"]
          looseSuite =
            let opening = "<testsuite name=\"native\" " ++ joinWith " " [k ++ "=\"" ++ show v ++ "\"" | (k, v) <- counts loose] ++ ">"
             in [(opening, opening ++ "\n" ++ joinWith "\n" (map elementXml loose) ++ "\n</testsuite>") | not (null loose)]
       in map (renamed target) (found ++ looseSuite)
    renamed target (opening, xml) =
      let matches = attributeMatches opening
          values = M.fromList [(name, value) | (_, _, name, value) <- matches]
          caseCounts = counts (junitElements xml ["testcase"])
          numbers = [(key, if not (null v) && all isDigit v then read v else fromMaybe 0 (lookup key caseCounts)) | key <- ["tests", "failures", "errors", "skipped"], let v = fromMaybe "" (M.lookup key values)]
          opening' = case [(index, len) | (index, len, name, _) <- matches, name == "name"] of
            (index, len) : _ ->
              take index opening
                ++ " name=\""
                ++ escapeXml target
                ++ ": "
                ++ replace "\"" "&quot;" (fromMaybe "" (M.lookup "name" values))
                ++ "\""
                ++ drop (index + len) opening
            [] ->
              if "<testsuite" `isPrefixOf` opening && not (maybe False wordChar (listToMaybe' (drop 10 opening)))
                then "<testsuite name=\"" ++ escapeXml target ++ "\"" ++ drop 10 opening
                else opening
       in (numbers, opening' ++ drop (length opening) xml)
    counted key (numbers, _) = fromMaybe 0 (lookup key numbers) :: Integer
    listToMaybe' = \case
      c : _ -> Just c
      [] -> Nothing

-- | junitCounts(cases): the tests, and those with each kind of native
-- outcome.
counts :: [Element] -> [(String, Integer)]
counts cases =
  ("tests", fromIntegral (length cases))
    : [ (if name == "skipped" then name else name ++ "s", fromIntegral (length [() | kinds <- statuses, name `elem` kinds]))
      | name <- ["failure", "error", "skipped"]
      ]
  where
    statuses = [nub (map elementName (junitElements (elementXml test) ["failure", "error", "skipped"])) | test <- cases]

joinWith :: String -> [String] -> String
joinWith _ [] = ""
joinWith separator items = foldr1 (\a b -> a ++ separator ++ b) items

-- | junitFromTests: JUnit XML for a runner that writes none.
junitFromTests :: [Json] -> String
junitFromTests tests =
  "<testsuite name=\"lawspec\" tests=\""
    ++ show (length tests)
    ++ "\" failures=\""
    ++ show (count "failed")
    ++ "\""
    ++ (if count "incomplete" > 0 then " errors=\"" ++ show (count "incomplete") ++ "\"" else "")
    ++ (if count "skipped" > 0 then " skipped=\"" ++ show (count "skipped") ++ "\"" else "")
    ++ ">\n"
    ++ joinWith "\n" (map testcase tests)
    ++ "\n</testsuite>"
  where
    status test = member "status" test
    count name = length [() | test <- tests, status test == Just (JString name)]
    text key test = maybe "undefined" jsString (member key test)
    classname test = case member "identity" test of
      Just (JString identity) | Just at <- lastSeparator identity, at > 0 -> take at identity
      _ -> maybe "" jsString (member "classname" test)
    lastSeparator identity = case [i | (i, rest) <- zip [0 :: Int ..] (suffixes identity), "::" `isPrefixOf` rest] of
      [] -> Nothing
      found -> Just (last found)
    suffixes s = case s of
      [] -> []
      _ : rest -> s : suffixes rest
    orText key fallback test = case member key test of
      Just JNull -> fallback
      Just value -> jsString value
      Nothing -> fallback
    testcase test =
      "  <testcase classname=\""
        ++ escapeXml (classname test)
        ++ "\" name=\""
        ++ escapeXml (text "name" test)
        ++ "\""
        ++ (case member "time" test of Just (JNumber n) -> " time=\"" ++ numberText n ++ "\""; _ -> "")
        ++ case status test of
          Just (JString "failed") -> "><failure message=\"" ++ escapeXml (orText "failure" "failed" test) ++ "\"/></testcase>"
          Just (JString "incomplete") ->
            "><properties><property name=\"lawspec.status\" value=\"incomplete\"/></properties><error message=\""
              ++ escapeXml (orText "failure" (orText "reason" "incomplete execution" test) test)
              ++ "\"/></testcase>"
          Just (JString "skipped") -> "><skipped message=\"" ++ escapeXml (orText "reason" "skipped" test) ++ "\"/></testcase>"
          _ -> "/>"

-- | Number.prototype.toFixed: the multiple of 10^-digits nearest the
-- double's exact value, the larger on a tie.
toFixed :: Int -> Double -> String
toFixed digits value
  | isNaN value = "NaN"
  | abs value >= 1e21 = numberText (fromFloatDigits value)
  | otherwise = sign ++ whole ++ (if digits > 0 then "." ++ fraction else "")
  where
    exact = toRational (abs value)
    scaled = exact * (10 ^ digits)
    n = let f = floor scaled :: Integer in if scaled - fromInteger f >= 1 / 2 then f + 1 else f
    text = show n
    padded = replicate (digits + 1 - length text) '0' ++ text
    whole = take (length padded - digits) padded
    fraction = drop (length padded - digits) padded
    sign = if value < 0 then "-" else ""
