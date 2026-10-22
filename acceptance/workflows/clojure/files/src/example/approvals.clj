;; User-owned LawSpec adapter: the approve workflow under the real clock.
(ns example.approvals
  "The adapters of example.approvals."
  (:require [example.workflows :as workflows]
            [lawspec.clojure :as ls])
  (:import (java.util HashMap)
           (lawspec.runtime LawSpecRuntime$WorkflowRuntime)
           (lawspec.data Order)
           (lawspec.definitions.example Workflows)))

(defn- approve [number]
  (Workflows/approve (.context (LawSpecRuntime$WorkflowRuntime. nil 0) (HashMap.)) (Order. (long number))))

;; Approves an order: whether two of order -1's slow checks that started
;; during this call overlapped in time. Run one after the other they cannot
;; overlap, however loaded the machine is.
(defn approved-quickly [number]
  (future
    (let [started (System/nanoTime)]
      (approve number)
      (or (not= number -1) (workflows/overlapped? started)))))

;; Approves an order: the messages of its failures, as reported.
(defn approval-errors [number]
  (future
    (reset! workflows/finished [])
    (let [[side error] (ls/->clojure (approve number))]
      (if (and (= side :left) (= :approve-error/approve-failures (ls/tag error)))
        (vec (keep :error (:error error)))
        []))))
