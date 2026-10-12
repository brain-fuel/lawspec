;; User-owned LawSpec adapter: native code that gets lawspec.crypto's
;; handlers as arguments.
(ns example.crypto
  "The adapters of example.crypto."
  (:require [lawspec.clojure :as ls])
  (:import (java.nio.charset StandardCharsets)
           (java.util Arrays)))

;; (Bytes -> Bytes)
(defn fingerprint [hash message]
  (Arrays/copyOf ^bytes (:value (ls/op hash :sha3 message)) 8))

;; (Bytes -> Bool)
(defn round-trip [aead message]
  (let [key (ls/op aead :aead-key)
        label (.getBytes "round trip" StandardCharsets/UTF_8)
        opened (ls/op aead :unseal key (ls/op aead :seal key message label) label)]
    (boolean (and opened (Arrays/equals ^bytes opened ^bytes message)))))
