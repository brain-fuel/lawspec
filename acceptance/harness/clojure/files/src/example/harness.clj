;; User-owned LawSpec adapter.
(ns example.harness
  "The adapters of example.harness."
  (:require [lawspec.clojure :as ls]))

;; (example.harness::type::Order -> Int32)
(defn discount [{:keys [items total]}]
  ;; Ten percent off orders of more than ten items.
  (if (> items 10) (quot total 10) 0))

;; (Int32 -> Int32)
(defn round-cents [cents]
  ;; To the nearest ten cents, halves down: known to break a law.
  (* (quot (+ cents 4) 10) 10))

;; (Int32 -> Bool)
(defn book [ledger cents]
  (ls/op ledger :accept cents))

(defn ledger-handler
  "The native handler of Ledger: accept."
  []
  {:accept (fn [cents] (pos? cents))})
