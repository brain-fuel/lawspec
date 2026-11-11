// The build of apache/pekko-samples' pekko-sample-fsm-scala for LawSpec's
// checks: the sample's own dependencies, with Pekko at 1.7.1 instead of the
// sample's 1.5.0 (LawSpec's Pekko runtime is built against 1.7.1), and the
// test kits the checks use.
//> using scala 3.9.0
//> using options -deprecation -feature
//> using javaOpt --sun-misc-unsafe-memory-access=allow
//> using resourceDir src/main/resources
//> using dep org.apache.pekko::pekko-actor-typed:1.7.1
//> using dep ch.qos.logback:logback-classic:1.3.15
//> using test.dep org.apache.pekko::pekko-actor-testkit-typed:1.7.1
//> using test.dep org.apache.pekko::pekko-persistence-testkit:1.7.1
//> using test.dep org.scalacheck::scalacheck:1.20.0
//> using test.dep org.scalatest::scalatest-funsuite:3.2.20
