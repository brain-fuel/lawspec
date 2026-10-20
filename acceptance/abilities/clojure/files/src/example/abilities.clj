;; User-owned LawSpec adapter: a native Gateway handler and a native adapter
;; that uses Gateway through the handler it is given.
(ns example.abilities
  "The adapters of example.abilities."
  (:require [lawspec.clojure :as ls]))

;; (Int32 -> Bool)
(defn charge
  [gateway value0]
  (let [payment (ls/op gateway :authorize value0)]
    (and (= :payment/approved (ls/tag payment))
         (= value0 (:cents (ls/op gateway :capture (:value payment)))))))

(defn gateway-handler
  "The native handler of Gateway: authorize, capture, fee."
  []
  {:authorize (fn [cents]
                (if (neg? cents)
                  :payment/declined
                  {:lawspec/tag :payment/approved :value cents}))
   :capture (fn [cents] {:lawspec/tag :receipt/receipt :cents cents})
   :fee (fn [] 25)})
