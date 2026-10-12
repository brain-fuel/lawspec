;; User-owned LawSpec adapter: rows are {:lawspec/tag :row/cell :head x
;; :tail row} down to :row/end.
(ns example.arithmetic
  "The adapters of example.arithmetic."
  (:require [lawspec.clojure :as ls]))

(defn- row-length [row]
  (count (take-while #(= :row/cell (ls/tag %)) (iterate :tail row))))

(defn mirror [tree]
  (if (= :perfect/node (ls/tag tree))
    {:lawspec/tag :perfect/node :left (mirror (:right tree)) :right (mirror (:left tree))}
    tree))

(defn area [{:keys [rows columns]}]
  (*' (row-length rows) (row-length columns)))

(defn duplicate [row] {:lawspec/tag :halves/halves :front row :back row})

(defn count-pairs [row] {:lawspec/tag :pairs/pairs :items row})

(defn drop-first [row] {:lawspec/tag :rest/rest :items row})
