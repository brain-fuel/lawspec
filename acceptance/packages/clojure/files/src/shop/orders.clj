;; User-owned LawSpec adapter. Two units declare a Currency, so their tags
;; carry the units' names: :shop-orders-currency/gbp.
(ns shop.orders
  "The adapters of shop.orders.")

(defn settlement [currency]
  (case currency
    :shop-orders-currency/usd :shop-domain-currency/usd
    :shop-orders-currency/gbp :shop-domain-currency/eur))

(defn line-total [{:keys [price quantity]}]
  {:lawspec/tag :money/money
   :currency (:currency price)
   :cents (min (* (:cents price) (:value quantity)) 100000000)})

(defn cheaper [a b] (min a b))

(defn round-down [cents] (- cents (rem cents 100)))

;; Version 2 of shop.tax: no tax on nothing, the high band from 100.00.
(defn classify [cents]
  (cond
    (<= cents 0) :shop-tax-v2x0x0-rates-band/zero
    (< cents 10000) :shop-tax-v2x0x0-rates-band/low
    :else :shop-tax-v2x0x0-rates-band/high))
