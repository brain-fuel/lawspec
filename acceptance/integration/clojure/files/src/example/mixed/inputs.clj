(ns example.mixed.inputs
  "The adapters of example.mixed.inputs."
  (:refer-clojure :exclude [identity])
  (:require [clojure.string :as str]))

(defn normalize [text] (str/replace text " " "-"))
(defn identity [x] x)
