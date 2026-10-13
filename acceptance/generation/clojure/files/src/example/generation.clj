;; User-owned LawSpec adapter: the portable generator under test.
(ns example.generation
  "The adapters of example.generation."
  (:require [lawspec.clojure :as ls])
  (:import (lawspec.runtime LawSpecRuntime)))

(defn generated [type seed size count]
  (vec (LawSpecRuntime/generated ^String type (.longValue (biginteger seed)) (int size) (int count))))

(defn shrunk [type seed size]
  (vec (LawSpecRuntime/shrunk ^String type (.longValue (biginteger seed)) (int size))))
