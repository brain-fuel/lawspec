-- | A Java adapter stub as a Clojure adapter: the stub's class becomes a
-- generated bridge with the same methods, each calling the function of the
-- same name in the unit's Clojure namespace through lawspec.clojure's
-- conversions, and the user writes that namespace. A native handler class
-- becomes a function returning a map of the handler's operations.
-- ref:DEC-clojure-over-java
module LawSpec.Clojure.Bridge
  ( Stub(..), Item(..), Operation(..), bridgeJava, bridgeJavaDoc, clojureStub, boundHandlerJava, boundHandlerJavaDoc
  , kebab, clojureName, namespaceOf, clojurePath
  ) where

import Data.Char (isAlphaNum, isUpper, toLower)
import Data.List (intercalate, isPrefixOf, stripPrefix)

import qualified LawSpec.Code.Doc as D
import qualified LawSpec.JavaExpr as J
import LawSpec.JavaAbi (Stub(..), Item(..), Operation(..))

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
bridgeJava ns bound = D.render (D.Pretty 100) . bridgeJavaDoc ns bound

bridgeJavaDoc :: String -> (String -> Maybe (String, String)) -> Stub -> D.Doc
bridgeJavaDoc ns bound (Stub package imports className items) =
  D.lineComment 100 "// " ("Generated by LawSpec. Do not edit. The adapters are Clojure functions in " ++ ns ++ ".") <>
  D.hardline <>
  (if null package then mempty else D.text ("package " ++ package ++ ";") <> D.hardline <> D.hardline) <>
  (if null imports then mempty else statements (map D.text imports) <> D.hardline <> D.hardline) <>
  D.text "@SuppressWarnings(" <> J.quoted "unchecked" <> D.text ")" <> D.hardline <>
  braced (D.text ("public final class " ++ className))
    (separate (braced (D.text ("private " ++ className ++ "()")) mempty : map item items)) <> D.hardline
  where
    item (Function comments operation) = commentsDoc comments <>
      braced (methodHeader "public static " operation)
        (returning operation (J.call "lawspec.clojure.LawSpecClojure.invoke"
          ([D.text (className ++ ".class"), J.quoted (opName operation), J.quoted (maybe ns fst (bound (opName operation))),
            J.quoted (maybe (clojureName (opName operation)) snd (bound (opName operation)))] ++
           map (D.text . snd) (opParameters operation))))
    item (Handler comments name interface resource resourceLayout operations) = commentsDoc comments <>
      braced (D.group (D.text ("public static final class " ++ name) <>
        D.nest 4 (D.softline <> D.text ("implements " ++ interface))))
        (separate (fields ++ map (handlerOperation name) operations))
      where
        actualResource = maybe (D.text "java.lang.Object") id resourceLayout
        handlerCall arguments = J.call "lawspec.clojure.LawSpecClojure.handler"
          (J.quoted ns : J.quoted (kebab name) : arguments)
        fields | resource =
          [D.text "public final " <> actualResource <> D.text " resource;",
           D.text "private final java.lang.Object handler;",
           braced (D.text ("public " ++ name) <> D.delimit 4 "(" ")" [actualResource <> D.text " resource"])
             (statements [D.text "this.resource = resource;", assignment "this.handler" (handlerCall [D.text "resource"])])]
               | otherwise = [field "private final java.lang.Object handler" (handlerCall [])]
    handlerOperation owner operation = D.text "@Override" <> D.hardline <>
      braced (methodHeader "public " operation)
        (returning operation (operationCall owner operation))

statements :: [D.Doc] -> D.Doc
statements = D.joinWith D.hardline

separate :: [D.Doc] -> D.Doc
separate = D.joinWith (D.hardline <> D.hardline)

braced :: D.Doc -> D.Doc -> D.Doc
braced header body = header <> D.hardline <> D.block 2 body

commentsDoc :: [String] -> D.Doc
commentsDoc = mconcat . map comment
  where
    comment text = case stripPrefix "// " text of
      Just body -> D.lineComment 98 "// " body
      Nothing -> D.text text <> D.hardline

methodHeader :: String -> Operation -> D.Doc
methodHeader modifiers operation = D.group
  (D.text modifiers <> opResultLayout operation <> D.nest 4 (D.softline <>
    D.text (opName operation) <> D.delimit 4 "(" ")"
      [D.group (ty <> D.nest 4 (D.softline <> D.text name)) | (ty,name) <- opParameterLayouts operation]))

field :: String -> D.Doc -> D.Doc
field declaration value = D.group (D.text (declaration ++ " =") <> D.nest 4 (D.softline <> value) <> D.text ";")

assignment :: String -> D.Doc -> D.Doc
assignment name value = D.group (D.text (name ++ " =") <> D.nest 4 (D.softline <> value) <> D.text ";")

returning :: Operation -> D.Doc -> D.Doc
returning operation call
  | opResult operation == "void" = call <> D.text ";"
  | otherwise = D.group (D.text "return (" <> result <> D.text ") " <> call <> D.text ";")
  where
    result | boxed (opResult operation) /= opResult operation = D.text (boxed (opResult operation))
           | otherwise = opResultLayout operation

operationCall :: String -> Operation -> D.Doc
operationCall owner operation = J.call "lawspec.clojure.LawSpecClojure.operation"
  ([D.text "handler", D.text (owner ++ ".class"), J.quoted (opName operation), J.quoted (kebab (opName operation))] ++
   map (D.text . snd) (opParameters operation))

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
    -- A bound function is written elsewhere, in the namespace lawspec.edn names.
    items = [i | i <- allItems, case i of Function _ o -> bound (opName o) == Nothing; _ -> True]
    defined = [clojureName (opName o) | Function _ o <- items] ++ [kebab n | Handler _ n _ _ _ _ <- items]
    clashes = filter (`elem` clojureCore) defined
    item (Function comments (Operation _ name parameters label _ _)) =
      [""] ++ [";; " ++ drop 3 c | c <- comments, "// " `isPrefixOf` c] ++
      [ "(defn " ++ clojureName name
      , "  [" ++ unwords (map (kebab . snd) parameters) ++ "]"
      , "  (throw (ex-info " ++ show ("not implemented: " ++ label) ++ " {})))" ]
    item (Handler comments name _ resource _ operations) =
      [ ""
      , "(defn " ++ kebab name ] ++
      [ "  " ++ show (unwords (map stripDoc comments)) | not (null comments) ] ++
      [ "  [" ++ (if resource then "resource" else "") ++ "]"
      , "  {" ++ intercalate "\n   " [ ":" ++ kebab op ++ " (fn [" ++ unwords (map (kebab . snd) parameters) ++ "] (throw (ex-info "
                                     ++ show ("not implemented: " ++ label) ++ " {})))"
                                   | Operation _ op parameters label _ _ <- operations ] ++ "})" ]
    stripDoc c = unwords (filter (`notElem` ["/**", "*/", "*"]) (words c))

-- | A bound handler: the ability's interface over the Clojure map of its
-- operations that the bound function makes.
boundHandlerJava :: String -> String -> (String, String) -> [Operation] -> String
boundHandlerJava className interface binding = D.render (D.Pretty 100) . boundHandlerJavaDoc className interface binding

boundHandlerJavaDoc :: String -> String -> (String, String) -> [Operation] -> D.Doc
boundHandlerJavaDoc className interface (ns, function) operations =
  D.lineComment 100 "// " ("Generated by LawSpec. Do not edit. The bound handler " ++ ns ++ "/" ++ function ++ " as " ++ interface ++ ".") <>
  D.text "package lawspec.clojure.bound;" <> D.hardline <> D.hardline <>
  D.text "@SuppressWarnings(" <> J.quoted "unchecked" <> D.text ")" <> D.hardline <>
  braced (D.group (D.text ("public final class " ++ className) <> D.nest 4 (D.softline <> D.text ("implements " ++ interface))))
    (separate (field "private final java.lang.Object handler"
      (J.call "lawspec.clojure.LawSpecClojure.handler" [J.quoted ns, J.quoted function]) :
      [D.text "@Override" <> D.hardline <> braced (methodHeader "public " operation)
        (returning operation (operationCall className operation)) | operation <- operations])) <> D.hardline
