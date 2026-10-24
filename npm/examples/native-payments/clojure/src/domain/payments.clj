;; Application code over the model's payment data: Clojure binds functions,
;; not types, so money is {:lawspec/tag :money/money :amount 1.20M
;; :currency :currency/eur}.
(ns domain.payments
  "Payments: the functions lawspec.edn binds.")

(defn apply-fee [money] (update money :amount + 0.2M))

(defn restore [payment] payment)

(defn store [payments] payments)
