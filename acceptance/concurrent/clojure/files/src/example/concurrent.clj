;; User-owned LawSpec adapter: a queue, a set and a map shared between
;; threads, each an atom of a persistent collection, changed atomically.
(ns example.concurrent
  "The adapters of example.concurrent."
  (:require [lawspec.clojure :as ls]))

(def ^:private ids (atom 0))
(def ^:private structures (atom {}))

;; A structure by its handle; generated tests may name one first.
(defn- structure [handle empty]
  (let [id (:id handle)]
    (or (get @structures id)
        (get (swap! structures #(if (contains? % id) % (assoc % id (atom empty)))) id))))

(defn- queue [handle] (structure handle clojure.lang.PersistentQueue/EMPTY))
(defn- tags [handle] (structure handle #{}))
(defn- cache [handle] (structure handle {}))

(defn new-queue [_]
  (let [handle {:lawspec/tag :work-queue/work-queue :id (swap! ids inc)}]
    (queue handle)
    handle))

(defn offer [handle item]
  (future (swap! (queue handle) conj item) nil))

(defn poll [handle]
  (future
    (let [q (queue handle)
          [before] (swap-vals! q pop)]
      (peek before))))

(defn queue-size [handle]
  (future (count @(queue handle))))

(defn new-tags [_]
  (let [handle {:lawspec/tag :tags/tags :id (swap! ids inc)}]
    (tags handle)
    handle))

(defn tag [handle item]
  (future (let [[before] (swap-vals! (tags handle) conj item)] (not (contains? before item)))))

(defn untag [handle item]
  (future (let [[before] (swap-vals! (tags handle) disj item)] (contains? before item))))

(defn tagged [handle item]
  (future (contains? @(tags handle) item)))

(defn new-cache [_]
  (let [handle {:lawspec/tag :cache/cache :id (swap! ids inc)}]
    (cache handle)
    handle))

(defn store [handle k v]
  (future (let [[before] (swap-vals! (cache handle) assoc k v)] (get before k))))

(defn fetch [handle k]
  (future (get @(cache handle) k)))

(defn evict [handle k]
  (future (let [[before] (swap-vals! (cache handle) dissoc k)] (get before k))))
