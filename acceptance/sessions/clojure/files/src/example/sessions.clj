;; User-owned LawSpec adapter: adding through a server process, over the
;; typed channel ends generated from the Serve and Hire protocols. Each end
;; is used once: a step gives the next end.
(ns example.sessions
  "The adapters of example.sessions."
  (:import (lawspec.runtime LawSpecRuntime)
           (lawspec.sessions Hire Serve)))

;; The server: receive two numbers, send their sum.
(defn- serve [server]
  (let [a (.receive server)
        b (.receive (.next a))]
    (.send (.next b) (+ (long (.value a)) (long (.value b))))))

;; The client: send both numbers, receive the sum.
(defn- ask [client a b]
  (let [after-a (.send client (int a))
        after-b (.send after-a (int b))]
    (.value (.receive after-b))))

(defn add [a b]
  (future
    (let [ends (Serve/open)
          server (LawSpecRuntime/spawn ^Runnable #(serve (.first ends)))
          sum (ask (.second ends) a b)]
      (.join server)
      sum)))

;; A manager is handed the server's end over a Hire channel and serves it.
(defn add-hired [a b]
  (future
    (let [served (Serve/open)
          hire (Hire/open)
          manager (LawSpecRuntime/spawn ^Runnable #(serve (.value (.receive (.second hire)))))]
      (.send (.first hire) (.first served))
      (let [sum (ask (.second served) a b)]
        (.join manager)
        sum))))
