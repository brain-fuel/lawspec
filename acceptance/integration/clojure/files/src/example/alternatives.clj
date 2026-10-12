(ns example.alternatives
  "The adapters of example.alternatives.")

(defn render [x] (Integer/toString x))
(defn reference-render [x] (str x))
(defn clamp [x] (max 0 x))
(defn reference-clamp [x] (if (neg? x) 0 x))
