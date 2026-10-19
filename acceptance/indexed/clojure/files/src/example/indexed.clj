;; User-owned LawSpec adapter: a Vec is {:lawspec/tag :vec/v-cons :head x
;; :tail vec} down to :vec/v-nil; a Tree is :tree/tip or :tree/bin.
(ns example.indexed
  "The adapters of example.indexed."
  (:refer-clojure :exclude [replicate flatten])
  (:require [lawspec.clojure :as ls]))

(defn- cons? [v] (= :vec/v-cons (ls/tag v)))
(defn- v-cons [head tail] {:lawspec/tag :vec/v-cons :value {:lawspec/tag :record4715df484a923df1661009999090568502db4ab1a072eddf70dc05c9f83e9cec/record :head head :tail tail}})

(defn replicate [n x]
  (reduce (fn [v _] (v-cons x v)) :vec/v-nil (range n)))

(defn append [xs ys]
  (if (cons? xs) (v-cons (:head (:value xs)) (append (:tail (:value xs)) ys)) ys))

(defn zip [xs flags]
  (if (and (cons? xs) (cons? flags))
    (v-cons (:head (:value flags)) (zip (:tail (:value xs)) (:tail (:value flags))))
    :vec/v-nil))

(defn flatten [tree]
  (if (= :tree/bin (ls/tag tree))
    (append (flatten (:left (:value tree))) (v-cons (:value (:value tree)) (flatten (:right (:value tree)))))
    :vec/v-nil))
