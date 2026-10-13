;; User-owned LawSpec adapter: a stack and an atomic counter.
(ns example.models
  "The adapters of example.models."
  (:refer-clojure :exclude [empty pop peek read]))

(defn empty [_] :stack/empty)

(defn push [top stack]
  {:lawspec/tag :push-flow/push-flow :state {:lawspec/tag :stack/push :top top :rest stack}})

;; The flow signature guarantees a nonempty stack.
(defn pop [{:keys [top rest]}]
  {:lawspec/tag :pop-flow/pop-flow :result top :state rest})

(defn peek [{:keys [top] :as stack}]
  {:lawspec/tag :peek-flow/peek-flow :result top :state stack})

(def ^:private counters (atom {}))
(def ^:private ids (atom 0))

(defn new-counter [_]
  (let [id (swap! ids inc)]
    (swap! counters assoc id (atom 0))
    {:lawspec/tag :counter/counter :id id}))

(defn increment [counter] (future (swap! (@counters (:id counter)) inc)))

(defn decrement [counter] (future (swap! (@counters (:id counter)) dec)))

(defn read [counter] (future @(@counters (:id counter))))
