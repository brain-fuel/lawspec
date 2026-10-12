;; User-owned LawSpec adapter: native handlers of Logs, Reader and Writer that
;; share the case's Store, an atom of each log's records, newest last.
(ns example.composition
  "The adapters of example.composition."
  (:require [lawspec.clojure :as ls]))

;; (Unit -> example.composition::type::Store)
(defn open-store [_]
  (atom {:logs {} :open true}))

;; (example.composition::type::Store -> Unit)
(defn close-store [store]
  (swap! store assoc :open false)
  nil)

(defn logs-handler
  "The native handler of Logs: create, append."
  [store]
  {:create (fn [log] (swap! store assoc-in [:logs log] []) nil)
   :append (fn [log record]
             (let [records (get-in @store [:logs log])]
               (when (nil? records) (ls/fail :problem/unknown-log))
               (when (empty? record) (ls/fail :problem/empty-record))
               (swap! store update-in [:logs log] conj record)
               (count records)))})

(defn reader-handler
  "The native handler of Reader: size."
  [store]
  {:size (fn [log] (some-> (get-in @store [:logs log]) count))})

(defn writer-handler
  "The native handler of Writer: write, lastOffset."
  [store]
  (let [last-offset (atom nil)]
    {:write (fn [log record]
              (let [records (get-in @store [:logs log])]
                (if (or (nil? records) (empty? record))
                  false
                  (do (swap! store update-in [:logs log] conj record)
                      (reset! last-offset (count records))
                      true))))
     :last-offset (fn [] @last-offset)}))
