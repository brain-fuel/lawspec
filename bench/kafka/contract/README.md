The Kafka reference model of LawTwin's `lawtwin.kafka` contract (0.1.0), from
`contracts/kafka` of LawTwin at commit 3945e07547203392025259bb877065e1547bdc60,
under the MIT licence in `LICENSE`, re-expressed with LawSpec's newer features:
operations that `fails with KafkaError` instead of returning an `Either`, one
`cluster` handler for the Broker, Admin and GroupCoordinator abilities, field
access and record update, and bounded arithmetic. It is a fixture for
`lawspec-dev bench kafka`, which generates the model and drives its `cluster`
spec handler; see `../README.md`.
