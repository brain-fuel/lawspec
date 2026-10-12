;; User-owned LawSpec adapter: native handlers for the shop's abilities, and
;; a native adapter that fails with a typed failure.
(ns example.shop
  "The adapters of example.shop."
  (:require [lawspec.clojure :as ls]))

;; (Int32 -> Int32)
(defn refund
  [gateway value0]
  (when (> value0 100000) (ls/fail :payment-error/too-large))
  (:cents (ls/op gateway :capture value0)))

(defn log-handler
  "The native handler of Log: note."
  []
  (let [lines (atom [])]
    {:note (fn [line] (swap! lines conj line) nil)}))

(defn store-int32-handler
  "The native handler of Store Int32: load, save."
  []
  (let [value (atom 0)]
    {:load (fn [] @value)
     :save (fn [x] (reset! value x) nil)}))

(defn store-text-handler
  "The native handler of Store Text: load, save."
  []
  (let [value (atom "")]
    {:load (fn [] @value)
     :save (fn [x] (reset! value x) nil)}))

(defn meter-handler
  "The native handler of Meter: reading."
  []
  {:reading (fn [] 3)})
