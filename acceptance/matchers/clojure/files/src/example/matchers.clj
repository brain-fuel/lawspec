;; User-owned LawSpec adapters for the matchers example.
(ns example.matchers
  "The adapters of example.matchers."
  (:require [clojure.string :as str]))

;; (List (Int32) -> List (Int32))
(defn sort-items [items] (vec (sort items)))

;; (List (Text) -> List (Text))
(defn unique-tags [tags] (vec (distinct tags)))

;; (Int32 -> (Int32 -> Float64))
(defn average [a b] (/ (+ (double a) (double b)) 2))

;; (Text -> Text)
(defn slug [text] (str/join "-" (re-seq #"[a-z0-9]+" (.toLowerCase ^String text java.util.Locale/ROOT))))

;; (Int32 -> example.matchers::type::Order)
(defn ship [id] {:lawspec/tag :order/shipped :id id :carrier "post"})
