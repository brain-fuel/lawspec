;; User-owned LawSpec adapter: pause notes when it is called.
(ns example.sequencing
  "The adapters of example.sequencing.")

(defn note
  "Appends an event and the time to LAWSPEC_SCHEDULE_LOG, when it is set."
  [event n]
  (when-let [path (not-empty (System/getenv "LAWSPEC_SCHEDULE_LOG"))]
    (locking note
      (spit path (str event " " n " " (String/format java.util.Locale/ROOT "%.3f" (to-array [(/ (System/nanoTime) 1e6)])) "\n")
            :append true))))

;; (Int32 -> Bool)
(defn pause [n]
  (note "start" n)
  (Thread/sleep 5)
  (note "end" n)
  true)
