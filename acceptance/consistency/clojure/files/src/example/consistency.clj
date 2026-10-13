;; User-owned LawSpec adapter: a page-view counter with one replica per thread.
(ns example.consistency
  "The adapters of example.consistency."
  (:require [lawspec.clojure :as ls]))

;; Each counter's replicas: the views each thread counted.
(def ^:private replicas (atom {}))
(def ^:private ids (atom -1))

(defn new-views [_]
  (let [id (swap! ids inc)]
    (swap! replicas assoc id {})
    {:lawspec/tag :views/views :id id}))

(defn hit [views]
  (let [me (.threadId (Thread/currentThread))]
    (get-in (swap! replicas update-in [(:id views) me] (fnil inc 0)) [(:id views) me])))

(defn total [views]
  (reduce + 0 (vals (get @replicas (:id views)))))
