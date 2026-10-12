;; User-owned LawSpec adapter: adapters that fail with a typed failure, which
;; a law expects with `fails with`, and the native Gateway handler.
(ns example.failures
  "The adapters of example.failures."
  (:require [lawspec.clojure :as ls]))

;; (Int32 -> Int32)
(defn refund [amount]
  (when (> amount 5000) (ls/fail {:lawspec/tag :payment-error/too-large :limit 5000}))
  amount)

;; (Int32 -> Int32)
(defn settle [amount]
  (future
    (when (neg? amount) (ls/fail :payment-error/blocked))
    (when (zero? amount) (ls/fail {:lawspec/tag :payment-error/declined :message "there is nothing to settle"}))
    amount))

(defn gateway-handler
  "The native handler of Gateway: decide."
  []
  {:decide (fn [amount]
             (cond
               (neg? amount) :decision/block
               (odd? amount) {:lawspec/tag :decision/decline :reason "an odd amount"}
               :else :decision/approve))})
