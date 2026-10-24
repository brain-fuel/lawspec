;; Application code lawspec.edn binds: a payment, the till it takes money
;; with, and the errors it throws, which lawspec.edn maps to PayError.
(ns till.payments
  "Payments: a bound adapter, its till and its errors."
  (:require [lawspec.clojure :as ls]))

(defn- money [cents] {:lawspec/tag :money/money :cents cents})

(defn pay [till cents]
  (when (neg? cents) (throw (ex-info "negative" {:type :till/bad-amount})))
  (when (> cents 1000) (throw (ex-info "declined" {:type :till/card-declined})))
  (money (:cents (ls/op till :take (money cents)))))

;; A till that keeps what it takes: the production handler.
(defn native-till []
  (let [taken (atom 0)]
    {:take (fn [{:keys [cents]}] (swap! taken + cents) (money cents))
     :opening (fn [] (money 0))}))
