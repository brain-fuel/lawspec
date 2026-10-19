;; User-owned LawSpec adapter: a stack is {:lawspec/tag :stack/push :top x
;; :rest stack}, or :stack/empty.
(ns example.flow
  "The adapters of example.flow."
  (:refer-clojure :exclude [pop peek])
  (:require [lawspec.clojure :as ls]))

(defn push [top stack]
  {:lawspec/tag :push-flow/push-flow
   :state {:lawspec/tag :stack/push :value {:lawspec/tag :record6e70c38da816203dd3a94111f83b422c58c2d67a01c3842a3fd23715879f00be/record :top top :rest stack}}})

;; The flow signature guarantees a nonempty stack.
(defn pop [{{:keys [top rest]} :value}]
  {:lawspec/tag :pop-flow/pop-flow :result top :state rest})

(defn peek [{{:keys [top]} :value :as stack}]
  {:lawspec/tag :peek-flow/peek-flow :result top :state stack})
