(ns example.slug
  "The adapters of example.slug."
  (:require [clojure.string :as str]))

(defn normalize [text] (str/replace text " " "-"))
(defn reference-normalize [text] (str/replace text \space \-))
