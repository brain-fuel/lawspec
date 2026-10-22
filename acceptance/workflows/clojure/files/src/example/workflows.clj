;; User-owned LawSpec adapter.
(ns example.workflows
  "The adapters of example.workflows."
  (:import (java.util.concurrent CompletableFuture ForkJoinPool TimeUnit)))

(defn audit [_] true)

(defn waitlist [error]
  (if (= error :signup-error/unavailable)
    [:right {:lawspec/tag :account/account :name "waitlist" :age 18 :level 0}]
    [:left error]))

(defn check-name [{:keys [name] :as signup}]
  (if (empty? name) [:left :signup-error/missing-name] [:right signup]))

(defn check-age [{:keys [age] :as signup}]
  (if (< age 18) [:left "too young"] [:right signup]))

(defn open-account [{:keys [name age]}]
  (if (= name "taken")
    [:left :signup-error/unavailable]
    [:right {:lawspec/tag :account/account :name name :age age :level 1}]))

;; Each check records when it fails, so approval-errors can tell completion
;; order from declaration order.
(def finished (atom []))

;; Order -1's slow checks record when they ran, from the call to the result,
;; so approved-quickly can tell whether they ran at the same time. The record
;; is never cleared, so tests running at once cannot erase each other's.
(def spans (atom []))

(defn overlapped?
  "Whether two slow checks that started at or after since overlapped in time."
  [since]
  (let [ran (vec (filter (fn [[start]] (>= start since)) @spans))]
    (boolean (some (fn [[i [a b]]] (some (fn [[c d]] (and (< a d) (< c b))) (subvec ran (inc i))))
                   (map-indexed vector ran)))))

(defn- check [{:keys [number] :as order} millis problem]
  (let [start (System/nanoTime)]
  (CompletableFuture/supplyAsync
    (reify java.util.function.Supplier
      (get [_]
        (when (= number -1) (swap! spans conj [start (System/nanoTime)]))
        (if (>= number 0)
          [:right order]
          (do (swap! finished conj problem) [:left problem]))))
    (if (= number -1)
      (CompletableFuture/delayedExecutor millis TimeUnit/MILLISECONDS)
      (ForkJoinPool/commonPool)))))

;; Order -1's stock check takes 400ms; a negative order has no stock.
(defn check-stock [order] (check order 400 "no stock"))

;; Order -1's credit check takes 250ms; a negative order has no credit.
(defn check-credit [order] (check order 250 "no credit"))
