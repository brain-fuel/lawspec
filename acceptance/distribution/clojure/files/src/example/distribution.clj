;; User-owned LawSpec adapter: the wire encoding, and nodes talking over
;; in-memory, TCP and HTTP transports.
(ns example.distribution
  "The adapters of example.distribution."
  (:require [clojure.string :as str])
  (:import (java.nio.charset StandardCharsets)
           (java.time Duration)
           (lawspec.actors TallyActor)
           (lawspec.mailboxes LedgerMailbox)
           (lawspec.remote LawSpecRemote)
           (lawspec.runtime LawSpecNetwork LawSpecRuntime LawSpecRuntime$HttpTransport LawSpecRuntime$MemoryNetwork
                            LawSpecRuntime$Node LawSpecRuntime$TcpTransport LawSpecRuntime$Value)
           (lawspec.sessions Answering Doubling Handoff Passing)))

(defn encoded [type seed size count]
  (vec (LawSpecRuntime/wireEncoded ^String type (.longValue (biginteger seed)) (int size) (int count))))

(defn round-trips [type seed size count]
  (LawSpecRuntime/wireRoundTrips ^String type (.longValue (biginteger seed)) (int size) (int count)))

(defmacro ^:private with-nodes
  "Binds nodes, runs the body, and closes them all."
  [bindings & body]
  `(let ~bindings
     (try ~@body
          (finally ~@(for [n (reverse (take-nth 2 bindings))] `(.close ~n))))))

(defn- node [transport] (LawSpecRuntime$Node. transport))

(defn- int32 [n] (into-array LawSpecRuntime$Value [(LawSpecRuntime$Value. "Int32" (biginteger n))]))

(defn remote-shifted [n]
  (future
    (let [network (LawSpecRuntime$MemoryNetwork. (bit-and n 0xFFFF) 0.2 0.2 0)]
      (with-nodes [here (node (.transport network "here"))
                   there (node (.transport network "there"))]
        (LawSpecRemote/serve there)
        (.longValueExact ^BigInteger (.data (LawSpecRemote/evaluate here (.address there) "example.distribution::shifted" (int32 n))))))))

(defn open-tally [_] {:lawspec/tag :tally/tally :count 0})

(defn add [{:keys [count]} amount]
  (let [after (+ count amount)]
    {:lawspec/tag :pair/pair :first after :second {:lawspec/tag :tally/tally :count after}}))

(defn remote-adds [amount]
  (future
    (with-nodes [server (node (LawSpecRuntime$TcpTransport.))
                 client (node (LawSpecRuntime$TcpTransport.))]
      (let [address (.serve (TallyActor/start) server "tally")
            tally (TallyActor/connect client address)]
        (.add tally (short amount))
        (.add tally (short amount))))))

(defn remote-doubling [n]
  (future
    (with-nodes [server (node (LawSpecRuntime$HttpTransport.))
                 client (node (LawSpecRuntime$HttpTransport.))]
      (let [first-end (Doubling/listen server "doubling")
            second-end (Doubling/dial client (str (.address server) "/doubling"))
            worker (LawSpecRuntime/spawn ^Runnable #(let [got (.receive second-end)]
                                                    (.send (.next got) (* 2 (long (.value got))))))
            reply (.receive (.send first-end (int n)))]
        (.join worker)
        (.value reply)))))

(defn remote-ledger [n]
  (future
    (with-nodes [here (node (LawSpecRuntime$TcpTransport.))
                 there (node (LawSpecRuntime$TcpTransport.))]
      (let [ledger (LedgerMailbox/serve there "ledger")
            sender (LedgerMailbox/connect here (str (.address there) "/ledger"))
            timeout (Duration/ofSeconds 5)]
        (.send sender (long n))
        (.send sender (long n))
        (let [total (+ (.receive ledger timeout) (.receive ledger timeout))]
          ;; receive within: nothing more comes, so it gives nothing in time.
          (if (.isPresent (.receiveWithin ledger (Duration/ofMillis 20))) -1 total))))))

(defn remote-handoff [n]
  (future
    (with-nodes [here (node (LawSpecRuntime$TcpTransport.))
                 there (node (LawSpecRuntime$TcpTransport.))]
      ;; A local conversation on this node; its first end goes to the other.
      (let [ends (Doubling/open)
            worker (LawSpecRuntime/spawn ^Runnable #(let [got (.receive (.second ends))]
                                                    (.send (.next got) (* 2 (long (.value got))))))
            giving (Handoff/listen here "handoff")
            taking (Handoff/dial there (str (.address here) "/handoff"))]
        (.send giving (.first ends))
        (let [end (.value (.receive taking))
              reply (.receive (.send end (int n)))]
          (.join worker)
          (.value reply))))))

(defn remote-handoff-onward [n]
  (future
    (let [network (LawSpecRuntime$MemoryNetwork. (bit-and n 0xFFFF) 0.1 0.1 0.005)]
      (with-nodes [a (node (.transport network "a"))
                   b (node (.transport network "b"))
                   c (node (.transport network "c"))
                   d (node (.transport network "d"))]
        ;; A conversation between A and C, which sends at once; A's end moves
        ;; to B, then to D, and answers from there.
        (let [first-end (Answering/listen a "answering")
              second-end (.send (Answering/dial c (str (.address a) "/answering")) (int n))
              to-b (Passing/listen a "to-b")
              at-b (Passing/dial b (str (.address a) "/to-b"))
              _ (.send to-b first-end)
              moved (.value (.receive at-b))
              to-d (Passing/listen b "to-d")
              at-d (Passing/dial d (str (.address b) "/to-d"))
              _ (.send to-d moved)
              end (.value (.receive at-d))]
          ;; The end no longer needs A or B.
          (.close a)
          (.close b)
          (let [got (.receive end)]
            (.send (.next got) (* 2 (long (.value got))))
            (.value (.receive second-end))))))))

(defn- contains-bytes? [^bytes haystack ^bytes needle]
  (let [n (alength needle)]
    (boolean (some (fn [i] (java.util.Arrays/equals haystack (int i) (int (+ i n)) needle 0 n))
                   (range 0 (inc (- (alength haystack) n)))))))

;; A definition evaluated on another node: its request names the definition's
;; content hash, which shows on the wire only in the clear.
(defn sealed-on-the-wire [n]
  (future
    (let [name "example.distribution::shifted"
          digest (.getBytes (LawSpecRemote/digest name) StandardCharsets/UTF_8)
          seen (vec (for [insecure [false true]]
                      (let [network (LawSpecRuntime$MemoryNetwork. (bit-and n 0xFFFF) 0 0 0 true)
                            transport #(if insecure (.insecureTransportForTests network %) (.transport network %))]
                        (with-nodes [here (node (transport "here"))
                                     there (node (transport "there"))]
                          (LawSpecRemote/serve there)
                          (let [result (LawSpecRemote/evaluate here (.address there) name (int32 n))]
                            (if (not= (.longValueExact ^BigInteger (.data result)) (+ n 1000))
                              :wrong
                              (boolean (some #(contains-bytes? % digest) (.recorded network)))))))))]
      (= seen [false true]))))

(defn handshake-agrees [line]
  (let [f (str/split line #" " -1)]
    (and (= 13 (count f))
         (boolean (clojure.lang.Reflector/invokeStaticMethod LawSpecNetwork "handshakeVector" (to-array f))))))
