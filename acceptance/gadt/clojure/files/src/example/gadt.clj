;; User-owned LawSpec adapter: an expression's value, by a multimethod on the
;; constructor's tag. Only the number cases are numbers, so each function
;; meets only the cases its type allows.
(ns example.gadt
  "The adapters of example.gadt."
  (:require [lawspec.clojure :as ls]))

(defmulti evaluate "An expression's value." ls/tag)
(defmethod evaluate :expr/number [{:keys [value]}] value)
(defmethod evaluate :expr/plus [{:keys [left right]}] (+' (evaluate left) (evaluate right)))
(defmethod evaluate :expr/truth [{:keys [value]}] value)
(defmethod evaluate :expr/same [{:keys [left right]}] (= (evaluate left) (evaluate right)))
(defmethod evaluate :expr/negate [{:keys [operand]}] (not (evaluate operand)))
(defmethod evaluate :expr/both [{:keys [first second]}]
  {:lawspec/tag :pair/pair :first (evaluate first) :second (evaluate second)})

(defn eval-number [expr] (evaluate expr))

(defn eval-truth [expr] (evaluate expr))

(defn eval-pair [expr] (evaluate expr))

(defn fold [expr] {:lawspec/tag :expr/number :value (evaluate expr)})

(defn describe [shown] (:witness shown))
