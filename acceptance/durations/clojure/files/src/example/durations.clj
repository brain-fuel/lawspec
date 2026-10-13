;; User-owned LawSpec adapter. A Duration is a java.time.Duration.
(ns example.durations
  "The adapters of example.durations."
  (:require [lawspec.clojure :as ls])
  (:import (java.time Duration)))

(defn remaining [^Duration budget ^Duration spent]
  (if (>= (compare spent budget) 0)
    Duration/ZERO
    (.minus budget spent)))
