;; User-owned LawSpec adapter: native code that gets the built-in abilities'
;; handlers as arguments.
(ns example.builtins
  "The adapters of example.builtins."
  (:require [lawspec.clojure :as ls])
  (:import (java.net InetAddress InetSocketAddress ServerSocket)
           (java.time Duration)))

;; (Int32 -> lawspec.time::type::Duration)
(defn elapsed [clock n]
  (let [start (:value (ls/op clock :now))]
    (dotimes [_ n] (ls/op clock :now))
    (Duration/ofNanos (* 1000 (- (:value (ls/op clock :now)) start)))))

;; (Int32 -> Bytes)
(defn token [secure-random n]
  (ls/op secure-random :secure-bytes n))

;; (Int32 -> Bool)
(defn listening [ports _]
  (try
    (with-open [server (ServerSocket.)]
      (.setReuseAddress server true)
      (.bind server (InetSocketAddress. (InetAddress/getLoopbackAddress) (int (ls/op ports :free-port))))
      true)
    (catch java.io.IOException _ false)))

;; (Int32 -> Bool)
(defn charge [log n]
  (when (even? n)
    (ls/op log :log-message :log-level/info (str "charged " n))
    true))
