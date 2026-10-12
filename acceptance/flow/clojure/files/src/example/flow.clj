;; User-owned LawSpec adapter: a stack is {:lawspec/tag :stack/push :top x
;; :rest stack}, or :stack/empty.
(ns example.flow
  "The adapters of example.flow."
  (:refer-clojure :exclude [pop peek])
  (:require [lawspec.clojure :as ls]))

(defn push [top stack]
  {:lawspec/tag :push-flow/push-flow
   :state {:lawspec/tag :stack/push :top top :rest stack}})

;; The flow signature guarantees a nonempty stack.
(defn pop [{:keys [top rest]}]
  {:lawspec/tag :pop-flow/pop-flow :result top :state rest})

(defn peek [{:keys [top] :as stack}]
  {:lawspec/tag :peek-flow/peek-flow :result top :state stack})
