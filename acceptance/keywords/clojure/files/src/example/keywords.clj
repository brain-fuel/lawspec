;; User-owned LawSpec adapter. class names a clojure.core function, so the
;; namespace excludes it.
(ns example.keywords
  "The adapters of example.keywords."
  (:refer-clojure :exclude [class]))

(defn class [x] (*' x 2))
