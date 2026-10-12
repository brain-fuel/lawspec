;; The Kafka reference model's workload, driven through the generated cluster
;; spec handler of the Broker ability: produce across 100 partitions, a
;; consumer group of ten members fetching and committing with a rebalance,
;; then transactions. See bench/README.md.
(ns bench.kafka-bench
  (:import (java.nio ByteBuffer)
           (java.util Arrays List)
           (lawspec.abilities.lawtwin Kafka$Cluster)
           (lawspec.data IsolationLevel$ReadCommitted IsolationLevel$ReadUncommitted OffsetEntry
                         ProducerTag Record TopicPartition FetchResult)
           (lawspec.runtime LawSpecRuntime$Just LawSpecRuntime$Nothing))
  (:gen-class))

(set! *warn-on-reflection* true)

(def ^:const partitions 100)
(def ^:const members 10)
(def ^:const fetch-size 500)

(defn- tp ^TopicPartition [p] (TopicPartition. "bench" (int p)))

(defn- record ^Record [^long i]
  (let [key (.array (.putLong (ByteBuffer/allocate 8) i))
        value (byte-array 64)]
    (Arrays/fill value (byte 120))
    (Record. (LawSpecRuntime$Just. key) (LawSpecRuntime$Just. value) (List/of))))

(defn- phase [name ops start]
  (println (format "phase %s %d %.6f" name ops (/ (- (System/nanoTime) start) 1e9))))

(defn- memory [label]
  (dotimes [_ 3] (System/gc))
  (let [r (Runtime/getRuntime)]
    (println (str "memory " label " " (- (.totalMemory r) (.freeMemory r))))))

(defn run [^long scale]
  (let [broker (Kafka$Cluster.)
        all (System/nanoTime)
        total (atom 0)]
    (.createTopicsRequest broker "bench" (int partitions))
    (let [start (System/nanoTime)]
      (dotimes [i scale]
        (.produceRequest broker (tp (mod i partitions)) (LawSpecRuntime$Nothing.) (List/of (record i))))
      (phase "produce" scale start))
    (swap! total + scale)
    (memory "after-produce")
    (let [start (System/nanoTime)
          ops (atom 0)
          read (atom 0)
          names (mapv #(str "member-" %) (range members))
          generation (atom 0)]
      (doseq [m names]
        (reset! generation (.joinGroupRequest broker "g" ^String m (List/of "bench")))
        (swap! ops inc))
      (dotimes [round 2]
        (when (= round 1)
          (.leaveGroupRequest broker "g" ^String (peek names))
          (reset! generation (.joinGroupRequest broker "g" ^String (peek names) (List/of "bench")))
          (swap! ops + 2))
        (doseq [m names]
          (.heartbeatRequest broker "g" ^String m (int @generation))
          (let [assigned (.syncGroupRequest broker "g" ^String m (int @generation))]
            (swap! ops + 2)
            (doseq [^TopicPartition p assigned]
              (let [committed (.offsetFetchRequest broker "g" p)]
                (swap! ops inc)
                (loop [position (if (instance? LawSpecRuntime$Just committed) (long (.value ^LawSpecRuntime$Just committed)) 0)]
                  (let [^FetchResult r (.fetchRequest broker p position (int fetch-size) (IsolationLevel$ReadUncommitted.))
                        end (if (zero? round) (quot (.highWatermark r) 2) (.highWatermark r))]
                    (swap! ops inc)
                    (when-not (or (.isEmpty (.records r)) (>= position end))
                      (swap! read + (.size (.records r)))
                      (.offsetCommitRequest broker "g" ^String m (int @generation) (List/of (OffsetEntry. p (.nextOffset r))))
                      (swap! ops inc)
                      (recur (long (.nextOffset r)))))))))))
      (phase "consume" @ops start)
      (swap! total + @ops)
      (println (str "check records-read " @read)))
    (let [start (System/nanoTime)
          ops (atom 0)
          txns (max 1 (quot scale 100))
          id (.initProducerIdRequest broker (LawSpecRuntime$Just. "tx"))
          sequences (int-array partitions)]
      (swap! ops inc)
      (dotimes [t txns]
        (let [parts [(mod (* 2 t) partitions) (mod (inc (* 2 t)) partitions)]]
          (.addPartitionsToTxnRequest broker "tx" (.producerId id) (.producerEpoch id) (List/of (tp (first parts)) (tp (second parts))))
          (doseq [p parts]
            (let [tag (ProducerTag. (.producerId id) (.producerEpoch id) (int (aget sequences p)))]
              (aset-int sequences p (inc (aget sequences p)))
              (.produceRequest broker (tp p) (LawSpecRuntime$Just. tag) (List/of (record t)))))
          (.txnOffsetCommitRequest broker "tx" (.producerId id) (.producerEpoch id) "g" (List/of (OffsetEntry. (tp (first parts)) (long t))))
          (.endTxnRequest broker "tx" (.producerId id) (.producerEpoch id) true)
          (swap! ops + 5)))
      (phase "transactions" @ops start)
      (swap! total + @ops))
    (phase "total" @total all)
    (memory "end")
    (let [^FetchResult r (.fetchRequest broker (tp 0) 0 (int 10) (IsolationLevel$ReadCommitted.))]
      (println (str "check committed-hw " (.highWatermark r)))
      ;; The embedding API: a refusal as a value, and the state kept and put back.
      (let [refused (.tryProduceRequest broker (TopicPartition. "missing" (int 0)) (LawSpecRuntime$Nothing.) (List/of (record 0)))]
        (println (str "check refused " (if (.failed refused) (.getSimpleName (class (.failure refused))) "nothing"))))
      (let [snapshot (.typedState broker)]
        (.produceRequest broker (tp 0) (LawSpecRuntime$Nothing.) (List/of (record 0)))
        (.setTypedState broker snapshot)
        (let [^FetchResult after (.fetchRequest broker (tp 0) 0 (int 10) (IsolationLevel$ReadCommitted.))]
          (println (str "check restored " (= (.highWatermark after) (.highWatermark r)))))))))

(defn -main [& args]
  (run (if (seq args) (parse-long (first args)) 1000000))
  (shutdown-agents))
