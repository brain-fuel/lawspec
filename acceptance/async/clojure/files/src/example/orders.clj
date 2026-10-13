;; User-owned LawSpec adapter: asynchronous adapters return futures.
(ns example.orders
  "The adapters of example.orders."
  (:require [lawspec.clojure :as ls]))

(defn- price-of [sku]
  (if (= sku "free") 0 (mod (.codePointCount ^String sku 0 (count sku)) 100)))

(defn price [sku] (future (price-of sku)))

(defn stock [sku] (future (.codePointCount ^String sku 0 (count sku))))

(defn _quote [sku] (price-of sku))
