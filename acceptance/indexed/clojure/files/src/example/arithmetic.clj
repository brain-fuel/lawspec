;; User-owned LawSpec adapter: rows are {:lawspec/tag :row/cell :head x
;; :tail row} down to :row/end.
(ns example.arithmetic
  "The adapters of example.arithmetic."
  (:require [lawspec.clojure :as ls]))

(defn- row-length [row]
  (count (take-while #(= :row/cell (ls/tag %)) (iterate #(get-in % [:value :tail]) row))))

(defn mirror [tree]
  (if (= :perfect/node (ls/tag tree))
    {:lawspec/tag :perfect/node :value {:lawspec/tag :recordbf7449c93365b618bf1a5ee73f403facd0ee7b030d813d5e8c718611ac928ef8/record :left (mirror (:right (:value tree))) :right (mirror (:left (:value tree)))}}
    tree))

(defn area [{{:keys [rows columns]} :value}]
  (*' (row-length rows) (row-length columns)))

(defn duplicate [row] {:lawspec/tag :halves/halves :value {:lawspec/tag :record90e2e86ad982c9c5e71a6cd286ab605cf2b3d771c37021fb930810c33933eb3d/record :front row :back row}})

(defn count-pairs [row] {:lawspec/tag :pairs/pairs :value row})

(defn drop-first [row] {:lawspec/tag :rest/rest :value row})
