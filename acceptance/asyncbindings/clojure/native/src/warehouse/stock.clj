;; Application code the warehouse adapters are bound to: some of it
;; asynchronous, as a real service client would be.
(ns warehouse.stock
  "Prices, quotes and shelves."
  (:refer-clojure :exclude [count]))

(defn- price [sku]
  (if (= sku "free") 0 (mod (.codePointCount ^String sku 0 (clojure.core/count sku)) 100)))

(defn price-of [sku] (future (price sku)))

(defn quote-of [sku] (price sku))

;; A stock count that several callers may change: an atom.
(defn shelf [& _] (atom 0))

(defn restock [shelf amount] (future (swap! shelf + amount) nil))

(defn count [shelf] (future @shelf))
