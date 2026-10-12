;; User-owned LawSpec adapter: an order is validated, then priced, each step
;; [:right value] or [:left error].
(ns example.ordering
  "The adapters of example.ordering."
  (:require [lawspec.clojure :as ls]))

(defn first-line [lines] (first (:value lines)))

(defn validate-order [{:keys [id quantity]}]
  (cond
    (empty? id) [:left :order-error/invalid-order-id]
    (not (<= 1 quantity 1000)) [:left :order-error/invalid-quantity]
    :else [:right {:lawspec/tag :validated-order/validated-order
                   :id {:lawspec/tag :order-id/order-id :value id}
                   :quantity {:lawspec/tag :unit-quantity/unit-quantity :value quantity}}]))

(defn price-order [{:keys [id quantity] :as order}]
  (let [total (* (:value quantity) 25)]
    (if (> total 20000)
      [:left :order-error/price-too-high]
      [:right {:lawspec/tag :priced-order/priced-order :id id :quantity quantity :total total}])))
