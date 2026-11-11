;; User-owned LawSpec adapter: a tab's handlers, run inside an actor.
;; Each handler takes the state and gives its reply and the next state.
(ns example.restarts
  "The adapters of example.restarts."
  (:import (lawspec.actors BarSupervisor TabActor)))

(defn- tab [total] {:lawspec/tag :tab/tab :total total})
(defn- reply [value state] {:lawspec/tag :pair/pair :first value :second state})

(defn open-tab [_] (tab 0))

(defn add [{:keys [total]} amount]
  (let [after (+ total amount)]
    (reply after (tab after))))

(defn total [{:keys [total] :as state}] (reply total state))

(defn keeps-total [amount]
  (let [^BarSupervisor bar (BarSupervisor/start)
        ^TabActor actor (.tab bar)]
    (.add actor (short amount))
    (.crash actor)
    (let [kept (.total actor)]
      (.stop bar)
      kept)))
