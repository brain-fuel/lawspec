(ns example.currying
  "The adapters of example.currying."
  (:refer-clojure :exclude [format])
  (:require [clojure.string :as str]
            [lawspec.clojure :as ls]))

(defn sum-four [a b c d] (+' a b c d))
(defn format [prefix enabled port suffix] (str prefix (when enabled port) suffix))
(defn reference-format [prefix enabled port suffix] (str/join [prefix (if enabled (str port) "") suffix]))
(defn trim [x] (.strip ^String x))
