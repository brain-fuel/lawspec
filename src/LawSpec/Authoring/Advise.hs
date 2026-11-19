-- | The compiler's advise request: authoring.mjs advise, so the SDK, the
-- MCP server and the legacy CLI read native advice from the core instead
-- of parsing native sources in JavaScript. A request with a target is
-- inspected and its native sources analyzed (LawSpec.Authoring.Native);
-- one without is the compiler's own advice. Either way the report is
-- settled against the request's exceptions and the inspection's interface
-- and files are dropped. Native rows keep the member order the JavaScript
-- implementation gave them. ref:DEC-authoring-advisories
module LawSpec.Authoring.Advise
  ( advise,
    findingPairs,
    checkPairs,
  )
where

import Data.Aeson
import Data.Aeson.Encoding (encodingToLazyByteString, list, pair)
import qualified Data.Aeson.Key as K
import qualified Data.Aeson.KeyMap as KM
import qualified Data.ByteString.Lazy as B
import Data.Char (isSpace)
import Data.Foldable (toList)
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import qualified Data.Text as T
import LawSpec.Authoring.Native

-- | A JSON object in member order.
type Row = [(Text, Value)]

-- | Answer an advise request with the compiler's dispatch for the
-- inspection (or compiler advice) it needs; a malformed exception list is
-- the given failure.
advise :: (B.ByteString -> B.ByteString) -> (Text -> B.ByteString) -> Object -> B.ByteString
advise dispatch failure request =
  case decode response of
    Just (Object result)
      | not (failed result) -> settled result
    _ -> response
  where
    targeted = maybe False truthy (KM.lookup "target" request)
    target = case KM.lookup "target" request of
      Just (String text) -> T.unpack text
      _ -> ""
    forwarded =
      KM.insert "method" (String (if targeted then "inspect" else "advise"))
        $ KM.insert "advice" (Bool True)
        $ KM.insertWith (\_ old -> old) "schemaVersion" (Number 5)
        $ foldr KM.delete request ["nativeSources", "exceptions", "strict", "method"]
    response = dispatch (encode (Object forwarded))
    failed result = case KM.lookup "diagnostics" result of
      Just (Array items) -> not (null items)
      _ -> False
    settled result =
      let report = case KM.lookup "advice" result of
            Just (Object o) -> [(K.toText k, v) | (k, v) <- KM.toList o]
            _ -> [("findings", Array mempty), ("checks", Array mempty)]
          (findings, checks)
            | targeted =
                analyze
                  target
                  (inspectionOf (Object result))
                  (bindingsOf (Object request))
                  (sourcesOf (fromMaybe Null (KM.lookup "nativeSources" request)))
            | otherwise = ([], [])
          rows key = case lookup key report of
            Just (Array items) -> [[(K.toText k, v) | (k, v) <- KM.toList o] | Object o <- toList items]
            _ -> []
          findingRows = rows "findings" ++ map (findingPairs (T.pack target)) findings
          checkRows = rows "checks" ++ map (checkPairs (T.pack target)) checks
       in case settle findingRows checkRows (fromMaybe (Array mempty) (KM.lookup "exceptions" request)) of
            Left problem -> failure problem
            Right (findings', ok) ->
              let member key value = case key of
                    "findings" -> list rowValue findings'
                    "checks" -> list rowValue checkRows
                    "ok" -> toEncoding ok
                    _ -> toEncoding value
                  advice = [(k, member k v) | (k, v) <- report] ++ [("ok", toEncoding ok) | "ok" `notElem` map fst report]
                  members = [(K.toText k, toEncoding v) | (k, v) <- KM.toList (foldr KM.delete result ["interface", "files", "advice"])]
                  ordered = [m | m <- members, fst m < "advice"] ++ [("advice", pairs (mconcat [pair (K.fromText k) v | (k, v) <- advice]))] ++ [m | m <- members, fst m > "advice"]
               in encodingToLazyByteString (pairs (mconcat [pair (K.fromText k) v | (k, v) <- ordered]))

-- | Replace a member in place, or append it.
update :: Text -> Value -> Row -> Row
update key value row
  | any ((== key) . fst) row = [(k, if k == key then value else v) | (k, v) <- row]
  | otherwise = row ++ [(key, value)]

-- | A row in its member order.
rowValue :: Row -> Encoding
rowValue row = pairs (mconcat [pair (K.fromText k) (toEncoding v) | (k, v) <- row])

-- | authoring.mjs settleAdvice over rows: a finding an exception names is
-- excepted with its reason; the report is ok without unresolved findings
-- and incomplete checks.
settle :: [Row] -> [Row] -> Value -> Either Text ([Row], Bool)
settle findings checks exceptions = case exceptions of
  Array items
    | all valid (toList items) ->
        let entries = [o | Object o <- toList items]
            excepted finding = case [e | e <- entries, KM.lookup "declaration" e == lookup "declaration" finding, KM.lookup "rule" e == lookup "rule" finding] of
              e : _ -> update "reason" (fromMaybe Null (KM.lookup "reason" e)) (update "status" (String "excepted") finding)
              [] -> finding
            findings' = map excepted findings
            ok =
              not (any (\f -> lookup "status" f == Just (String "unresolved")) findings')
                && all (\c -> lookup "status" c `elem` [Just (String "complete"), Just (String "not-applicable")]) checks
         in Right (findings', ok)
  _ -> Left "Authoring exceptions require a declaration, rule and nonempty reason"
  where
    valid (Object o) = all (nonblank . (`KM.lookup` o)) ["declaration", "reason", "rule"]
    valid _ = False
    nonblank (Just (String text)) = not (T.all isSpace text)
    nonblank _ = False

-- | A native finding in authoring.mjs's member order.
findingPairs :: Text -> Finding -> Row
findingPairs target finding =
  [ ("rule", String (findingRule finding)),
    ("target", String target),
    ("path", String (T.pack (findingPath finding))),
    ("declaration", String (findingDeclaration finding)),
    ("line", Number (fromIntegral (findingLine finding))),
    ("severity", String "warning"),
    ("status", String "unresolved"),
    ("message", String (findingMessage finding)),
    ("suggestion", String findingSuggestion)
  ]

-- | A native check in authoring.mjs's member order.
checkPairs :: Text -> Check -> Row
checkPairs target check =
  [("rule", String (checkRule check)), ("target", String target)]
    ++ [("path", String (T.pack path)) | Just path <- [checkPath check]]
    ++ [("status", String (checkStatus check))]
    ++ [("reason", String reason) | Just reason <- [checkReason check]]
    ++ [("scope", String checkScope) | checkScoped check]

-- | JavaScript truthiness.
truthy :: Value -> Bool
truthy = \case
  Null -> False
  Bool flag -> flag
  Number n -> n /= 0
  String text -> not (T.null text)
  _ -> True
