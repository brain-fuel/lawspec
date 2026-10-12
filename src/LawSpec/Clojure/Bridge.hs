-- | A Java adapter stub as a Clojure adapter: the stub's class becomes a
-- generated bridge with the same methods, each calling the function of the
-- same name in the unit's Clojure namespace through lawspec.clojure's
-- conversions, and the user writes that namespace. A native handler class
-- becomes a function returning a map of the handler's operations.
-- ref:DEC-clojure-over-java
module LawSpec.Clojure.Bridge
  ( Stub(..), Item(..), Operation(..), parseStub, bridgeJava, clojureStub, interfaceMethods, boundHandlerJava
  , kebab, clojureName, namespaceOf, clojurePath
  ) where

import Data.Char (isAlphaNum, isSpace, isUpper, toLower)
import Data.List (intercalate, isPrefixOf, isSuffixOf, stripPrefix)

-- | A parsed stub: its package, class and adapters.
data Stub = Stub { stubPackage :: String, stubImports :: [String], stubClass :: String, stubItems :: [Item] }
  deriving (Eq, Show)

data Item
  = Function { itemComments :: [String], itemOperation :: Operation }
  | Handler { itemComments :: [String], handlerClass :: String, handlerInterface :: String
            , handlerResource :: Bool, handlerOperations :: [Operation] }
  deriving (Eq, Show)

-- | A method: its result type, name, parameters (type, name) and the stub's
-- description of it.
data Operation = Operation { opResult :: String, opName :: String, opParameters :: [(String, String)], opLabel :: String }
  deriving (Eq, Show)

-- | The stub LawSpec's Java target writes for a unit.
parseStub :: String -> Either String Stub
parseStub source = do
  let ls = lines source
      package = [takeWhile (/= ';') rest | l <- ls, Just rest <- [stripPrefix "package " l]]
  (className, body) <- case break (isPrefixOf "public final class ") ls of
    (_, header : rest) -> Right (takeWhile (\c -> isAlphaNum c || c == '_') (drop (length ("public final class " :: String)) header), rest)
    _ -> Left "no adapter class in the stub"
  items <- classItems [] body
  pure (Stub (concat (take 1 package)) [l | l <- ls, "import " `isPrefixOf` l] className items)
  where
    trimmed = dropWhile isSpace
    classItems pending ls = case ls of
      [] -> Right []
      l : rest
        | trimmed l == "}" -> Right []
        | null (trimmed l) -> classItems [] rest
        | "//" `isPrefixOf` trimmed l -> classItems (pending ++ [trimmed l]) rest
        | "/**" `isPrefixOf` trimmed l -> let (doc, after) = comment ls in classItems (pending ++ doc) after
        | Just header <- stripPrefix "public static final class " (trimmed l) -> do
            let ws = words header
                name = concat (take 1 ws)
                interface = concat (take 1 (drop 2 ws))
            (resource, operations, after) <- handlerItems False [] rest
            (Handler pending name interface resource operations :) <$> classItems [] after
        | "public static " `isPrefixOf` trimmed l -> do
            (operation, after) <- method ls
            (Function pending operation :) <$> classItems [] after
        | otherwise -> classItems pending rest
    comment ls = let (doc, after) = break (isSuffixOf "*/" . trimmed) ls
                 in (map trimmed (doc ++ take 1 after), drop 1 after)
    handlerItems resource operations ls = case ls of
      [] -> Left "an unclosed handler class"
      l : rest
        | trimmed l == "}" -> Right (resource, operations, rest)
        | trimmed l == "public final java.lang.Object resource;" -> handlerItems True operations rest
        | "public " `isPrefixOf` trimmed l, "(java.lang.Object resource) {" `isSuffixOf` l ->
            handlerItems resource operations (drop 1 (dropWhile ((/= "}") . trimmed) rest))
        | trimmed l == "@Override" -> do
            (operation, after) <- method rest
            handlerItems resource (operations ++ [operation]) after
        | otherwise -> handlerItems resource operations rest
    -- A method header, which may span lines, its body's one throw, and its
    -- closing brace.
    method ls = do
      let (headerLines, rest) = break (isSuffixOf "{" . trimmed) ls
          header = unwords (map trimmed (headerLines ++ take 1 rest))
      -- The body is one throw, which may wrap.
      bodyAndClose <- case break ((== "}") . trimmed) (drop 1 rest) of
        (body@(first : _), _ : after) | "throw " `isPrefixOf` trimmed first -> Right (unwords (map trimmed body), after)
        _ -> Left ("an unexpected body for " ++ header)
      let label = takeWhile (/= '"') (drop 1 (dropWhile (/= '"') (fst bodyAndClose)))
      operation <- signature header label
      pure (operation, snd bodyAndClose)
    signature header label = do
      let plain = unwords (filter (`notElem` ["public", "static", "final"]) (words (takeWhile (/= '{') header)))
          (before, after) = break (== '(') plain
          parameters = takeWhile (/= ')') (reverse (dropWhile (/= ')') (reverse (drop 1 after))))
          ws = words before
      if null ws then Left ("no method name in " ++ header) else
        pure (Operation (unitFuture (unwords (init ws))) (last ws) (map parameter (splitTop parameters)) label)
    -- The Java stub writes an asynchronous Unit adapter's future as
    -- CompletableFuture<void>; the model's is of the Unit value.
    unitFuture t = case stripPrefix "java.util.concurrent.CompletableFuture<void>" t of
      Just "" -> "java.util.concurrent.CompletableFuture<lawspec.runtime.LawSpecRuntime.Value>"
      _ -> t
    parameter p = let ws = words p in (unwords (init ws), last ws)

-- | Commas outside angle brackets.
splitTop :: String -> [String]
splitTop s = filter (not . all isSpace) (go (0 :: Int) "" s)
  where
    go _ acc [] = [reverse acc]
    go depth acc (c : rest)
      | c == '<' = go (depth + 1) (c : acc) rest
      | c == '>' = go (depth - 1) (c : acc) rest
      | c == ',' && depth == 0 = reverse acc : go depth "" rest
      | otherwise = go depth (c : acc) rest

-- | A Java name in Clojure's words: countStoreLoad is count-store-load.
kebab :: String -> String
kebab = go True
  where
    go _ [] = []
    go first (c : rest)
      | isUpper c = (if first then [] else "-") ++ [toLower c] ++ go False rest
      | c == '_' = '-' : go False rest
      | otherwise = c : go False rest

-- | A function's Clojure name: a Java keyword's escape (a leading
-- underscore) is dropped unless the name is one of Clojure's special forms.
clojureName :: String -> String
clojureName name = case stripPrefix "_" name of
  Just rest | kebab rest `notElem` specialForms -> kebab rest
  Just rest -> '_' : kebab rest
  Nothing -> kebab name

specialForms :: [String]
specialForms = words "def if do let quote var fn loop recur throw try catch finally monitor-enter monitor-exit new set! letfn case"

-- | The unit's Clojure namespace: example.parse_port is example.parse-port.
namespaceOf :: String -> String
namespaceOf = map (\c -> if c == '_' then '-' else c)

-- | The namespace's file under src or test.
clojurePath :: String -> String
clojurePath ns = map (\c -> if c == '.' then '/' else if c == '-' then '_' else c) ns ++ ".clj"

-- | clojure.core's public names, which a function of the same name hides
-- only with :refer-clojure :exclude.
clojureCore :: [String]
clojureCore = concatMap words
  [ "* *' *1 *2 *3 *agent* *allow-unresolved-vars* *assert* *clojure-version*"
  , "*command-line-args* *compile-files* *compile-path* *compiler-options* *data-readers*"
  , "*default-data-reader-fn* *e *err* *file* *flush-on-newline* *fn-loader* *in*"
  , "*math-context* *ns* *out* *print-dup* *print-length* *print-level* *print-meta*"
  , "*print-namespace-maps* *print-readably* *read-eval* *reader-resolver* *repl* *source-path*"
  , "*suppress-read* *unchecked-math* *use-context-classloader* *verbose-defrecords*"
  , "*warn-on-reflection* + +' - -' -> ->> ->ArrayChunk ->Eduction ->Vec ->VecNode ->VecSeq"
  , "-cache-protocol-fn -reset-methods .. / < <= = == > >= EMPTY-NODE Inst NaN? PrintWriter-on"
  , "StackTraceElement->vec Throwable->map abs accessor aclone add-classpath add-tap add-watch"
  , "agent agent-error agent-errors aget alength alias all-ns alter alter-meta! alter-var-root"
  , "amap ancestors and any? apply areduce array-map as-> aset aset-boolean aset-byte aset-char"
  , "aset-double aset-float aset-int aset-long aset-short assert assoc assoc! assoc-in"
  , "associative? atom await await-for await1 bases bean bigdec bigint biginteger binding"
  , "bit-and bit-and-not bit-clear bit-flip bit-not bit-or bit-set bit-shift-left"
  , "bit-shift-right bit-test bit-xor boolean boolean-array boolean? booleans bound-fn"
  , "bound-fn* bound? bounded-count butlast byte byte-array bytes bytes? case cast cat char"
  , "char-array char-escape-string char-name-string char? chars chunk chunk-append chunk-buffer"
  , "chunk-cons chunk-first chunk-next chunk-rest chunked-seq? class class? clear-agent-errors"
  , "clojure-version coll? comment commute comp comparator compare compare-and-set! compile"
  , "complement completing concat cond cond-> cond->> condp conj conj! cons constantly"
  , "construct-proxy contains? count counted? create-ns create-struct cycle dec dec' decimal?"
  , "declare dedupe default-data-readers definline definterface defmacro defmethod defmulti"
  , "defn defn- defonce defprotocol defrecord defstruct deftype delay delay? deliver"
  , "denominator deref derive descendants destructure disj disj! dissoc dissoc! distinct"
  , "distinct? doall dorun doseq dosync dotimes doto double double-array double? doubles drop"
  , "drop-last drop-while eduction empty empty? ensure ensure-reduced enumeration-seq"
  , "error-handler error-mode eval even? every-pred every? ex-cause ex-data ex-info ex-message"
  , "extend extend-protocol extend-type extenders extends? false? ffirst file-seq filter"
  , "filterv find find-keyword find-ns find-protocol-impl find-protocol-method find-var first"
  , "flatten float float-array float? floats flush fn fn? fnext fnil for force format"
  , "frequencies future future-call future-cancel future-cancelled? future-done? future?"
  , "gen-class gen-interface gensym get get-in get-method get-proxy-class get-thread-bindings"
  , "get-validator group-by halt-when hash hash-combine hash-map hash-ordered-coll hash-set"
  , "hash-unordered-coll ident? identical? identity if-let if-not if-some ifn? import in-ns inc"
  , "inc' indexed? infinite? init-proxy inst-ms inst-ms* inst? instance? int int-array int?"
  , "integer? interleave intern interpose into into-array ints io! isa? iterate iteration"
  , "iterator-seq juxt keep keep-indexed key keys keyword keyword? last lazy-cat lazy-seq let"
  , "letfn line-seq list list* list? load load-file load-reader load-string loaded-libs locking"
  , "long long-array longs loop macroexpand macroexpand-1 make-array make-hierarchy map"
  , "map-entry? map-indexed map? mapcat mapv max max-key memfn memoize merge merge-with meta"
  , "method-sig methods min min-key mix-collection-hash mod munge name namespace"
  , "namespace-munge nat-int? neg-int? neg? newline next nfirst nil? nnext not not-any?"
  , "not-empty not-every? not= ns ns-aliases ns-imports ns-interns ns-map ns-name ns-publics"
  , "ns-refers ns-resolve ns-unalias ns-unmap nth nthnext nthrest num number? numerator"
  , "object-array odd? or parents parse-boolean parse-double parse-long parse-uuid partial"
  , "partition partition-all partition-by partitionv partitionv-all pcalls peek persistent!"
  , "pmap pop pop! pop-thread-bindings pos-int? pos? pr pr-str prefer-method prefers"
  , "primitives-classnames print print-ctor print-dup print-method print-simple print-str"
  , "printf println println-str prn prn-str promise proxy proxy-call-with-super proxy-mappings"
  , "proxy-name proxy-super push-thread-bindings pvalues qualified-ident? qualified-keyword?"
  , "qualified-symbol? quot rand rand-int rand-nth random-sample random-uuid range ratio?"
  , "rational? rationalize re-find re-groups re-matcher re-matches re-pattern re-seq read"
  , "read+string read-line read-string reader-conditional reader-conditional? realized? record?"
  , "reduce reduce-kv reduced reduced? reductions ref ref-history-count ref-max-history"
  , "ref-min-history ref-set refer refer-clojure reify release-pending-sends rem remove"
  , "remove-all-methods remove-method remove-ns remove-tap remove-watch repeat repeatedly"
  , "replace replicate require requiring-resolve reset! reset-meta! reset-vals! resolve rest"
  , "restart-agent resultset-seq reverse reversible? rseq rsubseq run! satisfies? second"
  , "select-keys send send-off send-via seq seq-to-map-for-destructuring seq? seqable? seque"
  , "sequence sequential? set set-agent-send-executor! set-agent-send-off-executor!"
  , "set-error-handler! set-error-mode! set-validator! set? short short-array shorts shuffle"
  , "shutdown-agents simple-ident? simple-keyword? simple-symbol? slurp some some-> some->>"
  , "some-fn some? sort sort-by sorted-map sorted-map-by sorted-set sorted-set-by sorted?"
  , "special-symbol? spit split-at split-with splitv-at str stream-into! stream-reduce!"
  , "stream-seq! stream-transduce! string? struct struct-map subs subseq subvec supers swap!"
  , "swap-vals! symbol symbol? sync tagged-literal tagged-literal? take take-last take-nth"
  , "take-while tap> test the-ns thread-bound? time to-array to-array-2d trampoline transduce"
  , "transient tree-seq true? type unchecked-add unchecked-add-int unchecked-byte"
  , "unchecked-char unchecked-dec unchecked-dec-int unchecked-divide-int unchecked-double"
  , "unchecked-float unchecked-inc unchecked-inc-int unchecked-int unchecked-long"
  , "unchecked-multiply unchecked-multiply-int unchecked-negate unchecked-negate-int"
  , "unchecked-remainder-int unchecked-short unchecked-subtract unchecked-subtract-int underive"
  , "unquote unquote-splicing unreduced unsigned-bit-shift-right update update-in update-keys"
  , "update-proxy update-vals uri? use uuid? val vals var-get var-set var? vary-meta vec vector"
  , "vector-of vector? volatile! volatile? vreset! vswap! when when-first when-let when-not"
  , "when-some while with-bindings with-bindings* with-in-str with-loading-context"
  , "with-local-vars with-meta with-open with-out-str with-precision with-redefs with-redefs-fn"
  , "xml-seq zero? zipmap" ]

boxed :: String -> String
boxed t = maybe t id (lookup t
  [("int", "java.lang.Integer"), ("long", "java.lang.Long"), ("short", "java.lang.Short"), ("byte", "java.lang.Byte"),
   ("boolean", "java.lang.Boolean"), ("double", "java.lang.Double"), ("float", "java.lang.Float"), ("char", "java.lang.Character")])

-- | The generated Java class: the stub's methods, calling the namespace.
bridgeJava :: String -> (String -> Maybe (String, String)) -> Stub -> String
bridgeJava ns bound (Stub package imports className items) = unlines $
  [ "// Generated by LawSpec. Do not edit. The adapters are Clojure functions in " ++ ns ++ "." ] ++
  [ "package " ++ package ++ ";" | not (null package) ] ++
  [ "" | not (null imports) ] ++ imports ++
  [ ""
  , "@SuppressWarnings(\"unchecked\")"
  , "public final class " ++ className ++ " {"
  , "  private " ++ className ++ "() {}" ] ++
  concatMap item items ++ ["}"]
  where
    item (Function comments (Operation result name parameters _)) =
      [""] ++ map ("  " ++) (filter ("//" `isPrefixOf`) comments) ++
      [ "  public static " ++ result ++ " " ++ name ++ "(" ++ params parameters ++ ") {"
      , "    " ++ returning result ("lawspec.clojure.LawSpecClojure.invoke(" ++ intercalate ", "
          ([className ++ ".class", quoted name, quoted (maybe ns fst (bound name)), quoted (maybe (clojureName name) snd (bound name))] ++ map snd parameters) ++ ")")
      , "  }" ]
    item (Handler comments name interface resource operations) =
      [""] ++ map ("  " ++) comments ++
      [ "  public static final class " ++ name ++ " implements " ++ interface ++ " {" ] ++
      (if resource
        then [ "    public final java.lang.Object resource;"
             , "    private final java.lang.Object handler;"
             , ""
             , "    public " ++ name ++ "(java.lang.Object resource) {"
             , "      this.resource = resource;"
             , "      this.handler = lawspec.clojure.LawSpecClojure.handler(" ++ quoted ns ++ ", " ++ quoted (kebab name) ++ ", resource);"
             , "    }" ]
        else [ "    private final java.lang.Object handler ="
             , "        lawspec.clojure.LawSpecClojure.handler(" ++ quoted ns ++ ", " ++ quoted (kebab name) ++ ");" ]) ++
      concat [ [ ""
               , "    @Override"
               , "    public " ++ result ++ " " ++ op ++ "(" ++ params parameters ++ ") {"
               , "      " ++ returning result ("lawspec.clojure.LawSpecClojure.operation(" ++ intercalate ", "
                   (["handler", name ++ ".class", quoted op, quoted (kebab op)] ++ map snd parameters) ++ ")")
               , "    }" ]
             | Operation result op parameters _ <- operations ] ++
      [ "  }" ]
    params ps = intercalate ", " [t ++ " " ++ n | (t, n) <- ps]
    returning "void" call = call ++ ";"
    returning result call = "return (" ++ boxed result ++ ") " ++ call ++ ";"
    quoted s = "\"" ++ s ++ "\""

-- | The namespace a user writes: a function per adapter, and a function per
-- native handler returning a map of its operations.
clojureStub :: String -> String -> (String -> Maybe (String, String)) -> Stub -> String
clojureStub unit ns bound (Stub _ _ _ allItems) = unlines $
  [ ";; User-owned LawSpec adapter."
  , "(ns " ++ ns
  , "  \"The adapters of " ++ unit ++ ".\""
  ] ++
  [ "  (:refer-clojure :exclude [" ++ unwords clashes ++ "])" | not (null clashes) ] ++
  [ "  (:require [lawspec.clojure :as ls]))" ] ++
  concatMap item items
  where
    -- A bound function is written elsewhere, in the namespace lawspec.json names.
    items = [i | i <- allItems, case i of Function _ o -> bound (opName o) == Nothing; _ -> True]
    defined = [clojureName (opName o) | Function _ o <- items] ++ [kebab n | Handler _ n _ _ _ <- items]
    clashes = filter (`elem` clojureCore) defined
    item (Function comments (Operation _ name parameters label)) =
      [""] ++ [";; " ++ drop 3 c | c <- comments, "// " `isPrefixOf` c] ++
      [ "(defn " ++ clojureName name
      , "  [" ++ unwords (map (kebab . snd) parameters) ++ "]"
      , "  (throw (ex-info " ++ show ("not implemented: " ++ label) ++ " {})))" ]
    item (Handler comments name _ resource operations) =
      [ ""
      , "(defn " ++ kebab name ] ++
      [ "  " ++ show (unwords (map stripDoc comments)) | not (null comments) ] ++
      [ "  [" ++ (if resource then "resource" else "") ++ "]"
      , "  {" ++ intercalate "\n   " [ ":" ++ kebab op ++ " (fn [" ++ unwords (map (kebab . snd) parameters) ++ "] (throw (ex-info "
                                     ++ show ("not implemented: " ++ label) ++ " {})))"
                                   | Operation _ op parameters label <- operations ] ++ "})" ]
    stripDoc c = unwords (filter (`notElem` ["/**", "*/", "*"]) (words c))

-- | The methods of a Java interface the model declares: name, result and
-- parameters, from its source (an abilities class's nested interface).
interfaceMethods :: String -> String -> [Operation]
interfaceMethods interface source =
  case dropWhile ((/= ("public interface " ++ interface ++ " {")) . dropWhile isSpace) (lines source) of
    _ : rest -> [ op | l <- takeWhile ((/= "}") . dropWhile isSpace) rest, Just op <- [declaration (dropWhile isSpace l)] ]
    [] -> []
  where
    declaration l
      | ";" `isSuffixOf` l, '(' `elem` l, not ("default " `isPrefixOf` l) =
          let (before, after) = break (== '(') (init l)
              ws = words before
              params = takeWhile (/= ')') (reverse (dropWhile (/= ')') (reverse (drop 1 after))))
          in if length ws < 2 then Nothing else
               Just (Operation (unwords (init ws)) (last ws) [let pw = words p in (unwords (init pw), last pw) | p <- splitTop params] "")
      | otherwise = Nothing

-- | A bound handler: the ability's interface over the Clojure map of its
-- operations that the bound function makes.
boundHandlerJava :: String -> String -> (String, String) -> [Operation] -> String
boundHandlerJava className interface (ns, function) operations = unlines $
  [ "// Generated by LawSpec. Do not edit. The bound handler " ++ ns ++ "/" ++ function ++ " as " ++ interface ++ "."
  , "package lawspec.clojure.bound;"
  , ""
  , "@SuppressWarnings(\"unchecked\")"
  , "public final class " ++ className ++ " implements " ++ interface ++ " {"
  , "  private final java.lang.Object handler ="
  , "      lawspec.clojure.LawSpecClojure.handler(\"" ++ ns ++ "\", \"" ++ function ++ "\");" ] ++
  concat [ [ ""
           , "  @Override"
           , "  public " ++ result ++ " " ++ op ++ "(" ++ intercalate ", " [t ++ " " ++ n | (t, n) <- parameters] ++ ") {"
           , "    " ++ (if result == "void" then "" else "return (" ++ boxed result ++ ") ") ++ "lawspec.clojure.LawSpecClojure.operation("
               ++ intercalate ", " (["handler", className ++ ".class", "\"" ++ op ++ "\"", "\"" ++ kebab op ++ "\""] ++ map snd parameters) ++ ");"
           , "  }" ]
         | Operation result op parameters _ <- operations ] ++
  [ "}" ]
