(ns example.parse-port
  "The adapters of example.parse_port.")

(defn valid-port [x] (<= 1 x 65535))
(defn render [x] (if (valid-port x) (str x) (throw (IllegalArgumentException. "invalid port"))))
(defn parse [text] (Integer/parseInt text))
