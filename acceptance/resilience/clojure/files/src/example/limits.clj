;; User-owned LawSpec adapter: the stages of a booking workflow.
(ns example.limits
  "The adapters of example.limits."
  (:import (java.util.concurrent CompletableFuture TimeUnit)))

(defn admit-ticket [ticket] [:right ticket])

(defn reserve-seat [ticket] [:right ticket])

(defn charge-card [ticket]
  (if (neg? (:number ticket)) [:left "declined"] [:right ticket]))

(defn release-seat [_] true)

(def ^:private quotes (atom 0))

(defn reset-quotes! [] (reset! quotes 0))

(defn- after [millis value]
  (CompletableFuture/supplyAsync
    (reify java.util.function.Supplier (get [_] value))
    (CompletableFuture/delayedExecutor millis TimeUnit/MILLISECONDS)))

;; Ticket -1's quote takes 600ms.
(defn fetch-quote [ticket]
  (if (= -1 (:number ticket)) (after 600 [:right ticket]) (future [:right ticket])))

;; Ticket -2's first quote (and every other one after) stalls.
(defn hedge-quote [ticket]
  (if (and (= -2 (:number ticket)) (odd? (swap! quotes inc)))
    (after 600 [:right ticket])
    (future [:right ticket])))
