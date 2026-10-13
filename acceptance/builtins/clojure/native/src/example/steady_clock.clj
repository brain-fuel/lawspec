;; Application code: a Clock bound in lawspec.json in place of the default
;; one. It keeps the default clock's readings.
(ns example.steady-clock
  "A steady Clock."
  (:require [lawspec.clojure :as ls])
  (:import (lawspec Time$ClockHandler)))

(defn steady-clock []
  (let [inner (Time$ClockHandler.)
        readings (atom 0)]
    {:now (fn []
            (swap! readings inc)
            (ls/->clojure (.now inner)))
     :sleep (fn [duration] (.sleep inner duration) nil)}))
