;; User-owned LawSpec adapters for the tables example.
(ns example.tables
  "The adapters of example.tables.")

;; (Int32 -> (Int32 -> Int32))
(defn shipping-cost [weight distance] (+ (* weight distance) (* 5 weight)))

;; (Int32 -> Text)
(defn label [n] (str "parcel " n))
