;; User-owned LawSpec adapter.
(ns shop.domain
  "The adapters of shop.domain.")

;; One-to-one rates keep the example exact.
(defn convert [currency money] (assoc money :currency currency))
