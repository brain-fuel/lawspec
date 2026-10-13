(ns example.algebra
  "The adapters of example.algebra."
  (:require [lawspec.clojure :as ls]))

(defn add [x y] (+' x y))
(defn multiply [x y] (*' x y))
(defn negate-value [x] (-' x))
(defn maximum-value [x y] (max x y))
(defn subtract-value [x y] (-' x y))
(defn divide-left [x y] (-' x y))
(defn divide-right [x y] (+' x y))
