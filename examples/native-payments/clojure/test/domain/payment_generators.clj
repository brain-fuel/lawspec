;; Application generators lawspec.json binds: test.check generators of the
;; model's tagged values.
(ns domain.payment-generators
  "Prices between 1.00 and 2.00 euros."
  (:require [clojure.test.check.generators :as gen]))

(defn prices []
  (gen/fmap (fn [cents] {:lawspec/tag :money/money :amount (BigDecimal/valueOf (long cents) 2) :currency :currency/eur})
            (gen/choose 100 200)))
