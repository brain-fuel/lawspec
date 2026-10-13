;; The application's job queue, shared between threads: an atom of a
;; persistent queue.
(ns work.jobs
  "Jobs: a queue the handle holds."
  (:refer-clojure :exclude [take]))

(defn jobs [& _] (atom clojure.lang.PersistentQueue/EMPTY))

(defn submit [jobs job] (swap! jobs conj job) nil)

(defn take [jobs]
  (let [[before] (swap-vals! jobs pop)]
    (peek before)))

(defn pending [jobs] (count @jobs))
