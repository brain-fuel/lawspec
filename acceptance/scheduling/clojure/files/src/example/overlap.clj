;; User-owned LawSpec adapter: nap notes when it starts and ends a sleep.
(ns example.overlap
  "The adapters of example.overlap."
  (:require [example.sequencing :refer [note]]))

;; (Int32 -> Bool)
(defn nap [n]
  (future
    (note "start" n)
    (Thread/sleep 300)
    (note "end" n)
    true))
