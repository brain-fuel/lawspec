(ns example.refundConformance)

(defn native-refund [{:keys [captured-amount requested-amount flagged]}]
  (cond
    (zero? requested-amount) :refund-decision/approved
    (> requested-amount captured-amount) :refund-decision/rejected
    flagged :refund-decision/review-required
    :else :refund-decision/approved))
