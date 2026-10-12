;; User-owned LawSpec adapter: a Vec is {:lawspec/tag :vec/v-cons :head x
;; :tail vec} down to :vec/v-nil; a Tree is :tree/tip or :tree/bin.
(ns example.indexed
  "The adapters of example.indexed."
  (:refer-clojure :exclude [replicate flatten])
  (:require [lawspec.clojure :as ls]))

(defn- cons? [v] (= :vec/v-cons (ls/tag v)))
(defn- v-cons [head tail] {:lawspec/tag :vec/v-cons :head head :tail tail})

(defn replicate [n x]
  (reduce (fn [v _] (v-cons x v)) :vec/v-nil (range n)))

(defn append [xs ys]
  (if (cons? xs) (v-cons (:head xs) (append (:tail xs) ys)) ys))

(defn zip [xs flags]
  (if (and (cons? xs) (cons? flags))
    (v-cons (:head flags) (zip (:tail xs) (:tail flags)))
    :vec/v-nil))

(defn flatten [tree]
  (if (= :tree/bin (ls/tag tree))
    (append (flatten (:left tree)) (v-cons (:value tree) (flatten (:right tree))))
    :vec/v-nil))
