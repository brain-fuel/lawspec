(ns example.atoi-codec
  "The adapters of example.atoi_codec.")

(defn itoa [value] (str value))

(defn atoi [value] (Integer/parseInt value))
