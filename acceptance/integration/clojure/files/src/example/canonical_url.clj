(ns example.canonical-url
  "The adapters of example.canonical_url."
  (:require [clojure.string :as str]))

(defn canonicalize [url] (str/replace url #"/+$" ""))
