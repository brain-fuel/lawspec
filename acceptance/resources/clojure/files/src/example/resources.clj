;; User-owned LawSpec adapters for the resources example.
(ns example.resources
  "The adapters of example.resources."
  (:refer-clojure :exclude [get])
  (:import (java.net InetAddress ServerSocket)
           (java.nio.file Files LinkOption Path)))

;; An in-memory store. At most three may be open at once, so a store that is
;; never closed is noticed.
(def ^:private open-stores (atom 0))
(def ^:private shared-items (atom {}))

(defn open-store [_]
  (when (>= @open-stores 3)
    (throw (IllegalStateException. "too many open stores: one was never closed")))
  (swap! open-stores inc)
  (atom {:items {} :open true}))

(defn close-store [store]
  (when (:open @store)
    (swap! store assoc :open false)
    (swap! open-stores dec))
  nil)

(defn clear-store [store] (swap! store assoc :items {}) nil)

(defn- open! [store]
  (when-not (:open @store) (throw (IllegalStateException. "the store is closed"))))

(defn put [store k v] (open! store) (swap! store assoc-in [:items k] v) nil)

(defn get [store k] (open! store) (clojure.core/get-in @store [:items k]))

(defn is-open [store] (:open @store))

(defn size [store] (count (:items @store)))

(defn- note-path ^Path [directory] (Path/of ^String directory (into-array String ["note.txt"])))

(defn write-note [directory n]
  (spit (str (note-path directory)) (str n))
  nil)

(defn read-note [directory]
  (let [note (note-path directory)]
    (when (Files/exists note (make-array LinkOption 0))
      (Integer/parseInt (slurp (str note))))))

(defn can-listen [port]
  (try
    (with-open [_ (ServerSocket. (int port) 1 (InetAddress/getLoopbackAddress))] true)
    (catch java.io.IOException _ false)))

(defn set-greeting [n] (System/setProperty "lawspec.example.greeting" (str n)) nil)

(defn greeting [_] (some-> (System/getProperty "lawspec.example.greeting") Integer/parseInt))

;; A pool that is costly to open: this JVM may open only one, so the suite
;; passes only if the harness shares it (share Pool per unit).
(def ^:private pools-opened (atom 0))

(defn open-pool [_]
  (when (>= @pools-opened 1)
    (throw (IllegalStateException. "a second pool was opened: the harness should share it")))
  (swap! pools-opened inc)
  (atom {:amount 0 :open true}))

(defn drain-pool [pool] (swap! pool assoc :amount 0) nil)

(defn close-pool [pool] (swap! pool assoc :open false) nil)

(defn fill [pool n]
  (when-not (:open @pool) (throw (IllegalStateException. "the pool is closed")))
  (swap! pool update :amount + n)
  nil)

(defn level [pool] (:amount @pool))
