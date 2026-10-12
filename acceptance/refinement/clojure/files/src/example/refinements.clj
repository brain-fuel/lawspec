(ns example.refinements
  "The adapters of example.refinements."
  (:refer-clojure :exclude [count]))

(defn add [a b] (+ a b))
(defn successor [a] (inc a))
(defn count [text] (.codePointCount ^String text 0 (clojure.core/count text)))
(defn preserve [a] a)
(defn positive [a] a)
(defn abstract-echo [a] a)
