;; User-owned LawSpec adapter: the workflow runtime under test.
(ns example.resilience
  "The adapters of example.resilience."
  (:require [example.limits :as limits])
  (:import (java.util HashMap)
           (lawspec.runtime LawSpecRuntime LawSpecRuntime$Retry LawSpecRuntime$SplitMix64
                            LawSpecRuntime$WorkflowRuntime LawSpecRuntime$VirtualClock
                            LawSpecRuntime$StagePolicy LawSpecRuntime$Value LawSpecRuntime$Data
                            LawSpecRuntime$Right LawSpecRuntime$Left)
           (lawspec.definitions.example Limits)
           (lawspec.data Ticket QuotedError$QuotedTimedOut)))

(defn- retry
  ([strategy delay step factor] (retry strategy delay step factor 0 nil))
  ([strategy delay step factor attempts when]
   (LawSpecRuntime$Retry. strategy (long delay) (long step) (long factor) -1 (long attempts) "none" when nil)))

(defn runtime-exponential-delay [delay factor attempt]
  (LawSpecRuntime/retryDelay (retry "exponential" delay 0 factor) (long attempt)))

(defn runtime-linear-delay [delay step attempt]
  (LawSpecRuntime/retryDelay (retry "linear" delay step 0) (long attempt)))

(defn runtime-fibonacci-delay [delay attempt]
  (LawSpecRuntime/retryDelay (retry "fibonacci" delay 0 0) (long attempt)))

(defn split-mix [seed n]
  (let [random (LawSpecRuntime$SplitMix64. (.longValue (biginteger seed)))]
    (vec (repeatedly n #(bigint (Long/toUnsignedString (.next random)))))))

(defn full-jitter [seed delay]
  (LawSpecRuntime/jittered "full" (long delay) 0 0 (LawSpecRuntime$SplitMix64. (.longValue (biginteger seed)))))

(defn- waits [attempts when]
  (let [runtime (LawSpecRuntime$WorkflowRuntime. (LawSpecRuntime$VirtualClock.) 0)
        failing (reify java.util.function.Supplier
                  (get [_] (LawSpecRuntime$Value. "Either" (LawSpecRuntime$Data. "Either::Left" [(LawSpecRuntime/integer64 0)]))))]
    (LawSpecRuntime/runStage (.context runtime (HashMap.))
                             (LawSpecRuntime$StagePolicy. "stage" (retry "exponential" 100000 0 2 attempts when) -1)
                             failing)
    (vec (for [event (.trace runtime) :when (= "sleep" (.kind event))] (.number event)))))

(defn retried-waits [attempts] (waits attempts nil))

(defn rejected-waits [attempts]
  (waits attempts (reify java.util.function.Function (apply [_ _] false))))

;; Calls the generated workflow at each time under one runtime.
(defn limited-at [times]
  (let [clock (LawSpecRuntime$VirtualClock.)
        runtime (LawSpecRuntime$WorkflowRuntime. clock 0)]
    (vec (for [time times]
           (do (set! (.time clock) (long time))
               (instance? LawSpecRuntime$Right (Limits/limited (.context runtime (HashMap.)) (Ticket. 0))))))))

;; Books a ticket under a fresh runtime: the stages whose undos ran.
(defn compensations-for [number]
  (let [runtime (LawSpecRuntime$WorkflowRuntime. (LawSpecRuntime$VirtualClock.) 0)]
    (Limits/book (.context runtime (HashMap.)) (Ticket. (long number)))
    (vec (for [event (.trace runtime) :when (= "compensate" (.kind event))] (.stage event)))))

;; Quotes a ticket under a runtime with the real clock: whether it succeeded
;; within 400ms, for ticket -2 through a hedged attempt.
(defn quote-hedged [number]
  (future
    (limits/reset-quotes!)
    (let [runtime (LawSpecRuntime$WorkflowRuntime. nil 0)
          started (System/nanoTime)
          result (Limits/hedged (.context runtime (HashMap.)) (Ticket. (long number)))
          quick (< (- (System/nanoTime) started) 400000000)
          hedged (some #(= "hedge" (.kind %)) (.trace runtime))]
      (boolean (and (instance? LawSpecRuntime$Right result) quick (or (not= number -2) hedged))))))

;; Quotes a ticket under a runtime with the real clock: whether it timed out.
(defn quote-timed-out [number]
  (future
    (let [runtime (LawSpecRuntime$WorkflowRuntime. nil 0)
          result (Limits/quoted (.context runtime (HashMap.)) (Ticket. (long number)))]
      (and (instance? LawSpecRuntime$Left result)
           (instance? QuotedError$QuotedTimedOut (.value ^LawSpecRuntime$Left result))))))
