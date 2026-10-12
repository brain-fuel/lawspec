;; User-owned LawSpec adapter: an account's handlers, run inside an actor.
;; Each handler takes the state and gives its reply and the next state.
(ns example.actors
  "The adapters of example.actors."
  (:import (lawspec.actors AccountActor BankSupervisor)
           (lawspec.runtime LawSpecRuntime)))

(defn- account [balance] {:lawspec/tag :account/account :balance balance})
(defn- reply [value state] {:lawspec/tag :pair/pair :first value :second state})

(defn open-account [_] (account 0))

(defn deposit [{:keys [balance]} amount]
  (let [after (+ balance amount)]
    (reply after (account after))))

(defn withdraw-all [{:keys [balance]}] (reply balance (account 0)))

(defn balance [{:keys [balance] :as state}] (reply balance state))

(defn close [_] (account 0))

(defn reopen [{:keys [balance]}] (account balance))

(defn deposit-twice [amount]
  (let [^AccountActor actor (AccountActor/start)]
    (LawSpecRuntime/par (into-array Runnable [#(.deposit actor (short amount)) #(.deposit actor (short amount))]))
    (let [total (.balance actor)]
      (.stop actor)
      total)))

(defn survives-crash [amount]
  (let [^BankSupervisor bank (BankSupervisor/start)
        ^AccountActor actor (.account bank)]
    (.deposit actor (short amount))
    (.crash actor)
    (let [total (.balance actor)]
      (.stop bank)
      total)))
