;; Application code: the Signature and KeyExchange handlers bound in
;; lawspec.edn in place of the defaults. They pass their operations on to
;; the defaults and count them.
(ns example.counting
  "Counting crypto handlers."
  (:require [lawspec.clojure :as ls])
  (:import (lawspec Crypto$KeyExchangeHandler Crypto$SignatureHandler)))

(defn counting-signer []
  (let [inner (Crypto$SignatureHandler.)
        count (atom 0)]
    {:signing-key-pair (fn [] (ls/op inner :signing-key-pair))
     :sign (fn [key message] (swap! count inc) (ls/op inner :sign key message))
     :verify (fn [key message signature] (ls/op inner :verify key message signature))}))

(defn counting-exchange []
  (let [inner (Crypto$KeyExchangeHandler.)
        count (atom 0)]
    {:exchange-key-pair (fn [] (ls/op inner :exchange-key-pair))
     :encapsulate (fn [public] (swap! count inc) (ls/op inner :encapsulate public))
     :decapsulate (fn [secret ciphertext] (ls/op inner :decapsulate secret ciphertext))}))
