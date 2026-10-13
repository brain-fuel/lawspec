;; User-owned LawSpec adapter: Clojure's persistent collections. A queue is a
;; vector from its front; a stack is a vector from its top.
(ns example.collections
  "The adapters of example.collections."
  (:refer-clojure :exclude [dedupe])
  (:require [lawspec.clojure :as ls]))

(defn dedupe [items] (set items))

(defn word-counts [words] (frequencies words))

(defn fifo [items] (vec items))

(defn lifo [items] (vec (reverse items)))

(defn rotate [queue]
  (if (seq queue) (conj (vec (rest queue)) (first queue)) queue))

;; Vectors compare by value, so they can be set elements directly.
(defn distinct-rows [rows] (set rows))
