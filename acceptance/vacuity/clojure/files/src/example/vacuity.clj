;; User-owned LawSpec adapter.
(ns example.vacuity
  "The adapters of example.vacuity."
  (:refer-clojure :exclude [keep])
  (:require [clojure.string :as string]))

;; shout :: (Text -> Text) — vacuity.lawspec:26
(defn shout
  [name]
  (string/upper-case name))

;; abbreviate :: (example.vacuity::type::Stage -> Text) — vacuity.lawspec:27
(defn abbreviate
  [stage]
  (:token stage))

;; accepts :: (example.vacuity::type::Proposal -> Bool) — vacuity.lawspec:28
;; Accepts only codes such as OFFER-2026-AB: no random record has one.
(defn accepts
  [offer]
  (boolean (and (re-matches #"OFFER-[0-9]{4}-[A-Z]{2}" (:code offer)) (pos? (:amount offer)))))

;; describe :: (example.vacuity::type::Proposal -> Text) — vacuity.lawspec:29
(defn describe
  [offer]
  (:code offer))

;; keep :: (Text -> Text) — vacuity.lawspec:30
(defn keep
  [key]
  key)
