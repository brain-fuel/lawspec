---
id: lawspec.how-to.check-pekko-actors
kind: how-to
title: Check Pekko actors with LawSpec
---
# Check Pekko actors with LawSpec

An actor you already wrote with Apache Pekko Typed can be checked against a
LawSpec [actor](../reference/language/actors.md). You state what the actor
should do as a model. A native binding names your behaviour and the message
for each handler. LawSpec then sends your actor generated runs of messages
and compares every reply with the model. The runs include crashes and
several callers at once. Your actor's code does not change.

This guide uses the Java samples of
[apache/pekko-samples](https://github.com/apache/pekko-samples) as worked
examples. Each one is an acceptance suite under `acceptance/pekko-samples`.
The samples' sources are vendored there unchanged, from upstream commit
`f9ce3d60a4f24b1844409e3153c7fbf361cc2506`, with their licence files. The
samples pin Pekko 1.5.0. The suites build them with Pekko 1.7.1, the version
LawSpec's Pekko checker is built against.

The Scala samples are checked as the Java ones are, with the same specs.
The field-by-field contract is in the
[native bindings reference](../reference/native-bindings.md#native-actors).

## Bind an event-sourced actor: the shopping cart

`pekko-sample-persistence-java` has a `ShoppingCart`, an
`EventSourcedBehavior`. Its commands answer `StatusReply<Summary>`: success
with the cart's summary, or an error. It rejects a duplicate item, a
quantity below one, an empty checkout, and any change once the cart is
checked out.

State the cart as an actor whose model keeps each item's quantity and
whether the cart is checked out. Each handler's reference says what the
cart answers:

```lawspec fragment
function modelAddItem
    (item :: Text where item = "apple" || item = "pear" || item = "plum")
    (quantity :: Int32 where quantity >= 0 && quantity <= 3)
    (b :: Basket) -> Pair Bool Basket is
  if b.checkedOut then Pair false b else
    first matching case of prelude.lookup item b.items :
      when Present held then Pair false b
      when Absent then
        if quantity <= 0 then Pair false b else Pair true (b with items = prelude.put item quantity b.items) end if
    end case
  end if
end function

actor cart :: Cart by Basket is
  start openCart by (emptyBasket ())
  restart keeps state
  on addItem by modelAddItem
  on removeItem by modelRemoveItem
  on adjustItemQuantity by modelAdjustItemQuantity
  on checkout by modelCheckout
  on items by modelItems
  on checkedOut by modelCheckedOut
end actor
```

`restart keeps state` says that after a crash the cart still has what it
had. The cart recovers it from its journal.

Then bind each handler to the sample's message under the Java target's
`native-bindings`:

```json
{"actors": [{
  "actor": "sample.persistence.cart::cart",
  "behavior": ["sample", "persistence", "ShoppingCart", "create"],
  "persistence": "event-sourced",
  "handlers": [
    {"handler": "addItem", "message": ["sample", "persistence", "ShoppingCart", "AddItem"],
     "replyTo": true, "reply": ["org", "apache", "pekko", "pattern", "StatusReply"],
     "replyArguments": [["sample", "persistence", "ShoppingCart", "Summary"]],
     "result": "isSuccess"},
    {"handler": "items", "message": ["sample", "persistence", "ShoppingCart", "Get"],
     "replyTo": true, "reply": ["sample", "persistence", "ShoppingCart", "Summary"],
     "resultField": "items"}
  ]
}]}
```

- `replyArguments` gives the reply's type arguments, so the generated ask
  makes an `ActorRef<StatusReply<Summary>>`.
- `result` names an accessor of the reply. `resultField` names a public
  field instead, as `Summary.items` is.
- `Get` is bound twice, once for the items and once for `checkedOut`. A
  handler is one reply value.

LawSpec runs the cart in Pekko's `ActorTestKit`, on the in-memory journal
of the persistence test kit. A crash stops the cart, and it starts again
with the same persistence id. A cart that forgets to persist an item fails
like this:

```text
model cart fails at step 3 of start(()); addItem("", 1); crash();
adjustItemQuantity("", 1): returned false; the model returns true
```

A cart that still takes items after checkout fails at `checkout(); addItem`.

## Bind an actor that knows its caller: the chopstick

In `pekko-sample-fsm-java`, a `Chopstick` remembers which hakker took it by
that hakker's `ActorRef`. `Put` only frees it when it comes from the same
address. A fresh reply address for every ask would never match.

Make the hakker the handler's first argument, and mark it as the caller:

```lawspec fragment
take :: Stick -> Hakker -> Pair Bool Stick
put :: Stick -> Hakker -> Stick

actor chopstick :: Stick by Holder is
  start openStick by Free
  on take by modelTake
  on put by modelPut
end actor
```

```json
{"handler": "take", "message": ["sample", "Chopstick", "Take"], "caller": true,
 "reply": ["sample", "Chopstick", "Answer"], "result": "isTaken"},
{"handler": "put", "message": ["sample", "Chopstick", "Put"], "caller": true}
```

Each hakker then gets one address for the whole run. `Take` carries it, and
the answer is the next message that address receives. `Put` has no reply,
so it is sent with `tell`. The sample's classes are package-private. The
generated wiring is placed in the behaviour's own package, so it can name
them.

A chopstick that grants itself twice fails at `take(Ghosh); take(Ghosh)`.
One that is never put down fails at `take(Krasser); put(Krasser);
take(Ghosh)`.

## Bind an actor that only sends: the hakker

A sample's `Hakker` answers no message. It thinks, its timers make it
hungry and then full, and it talks only to its two chopsticks. Bind it
unchanged by standing in for the chopsticks. Each one is a probe: LawSpec
passes the probe's address to the behaviour, hears what the hakker sends
it, and answers as the chopstick would.

```json
{"actor": "sample.hakkers::hakker",
 "behavior": ["sample", "Hakker", "create"],
 "behaviorArguments": [{"text": "Ghosh"}, {"probe": "left"}, {"probe": "right"}],
 "handlers": [
   {"handler": "think", "messageValue": ["sample", "Hakker", "Think", "INSTANCE"]},
   {"handler": "asksLeft", "probe": "left", "hears": ["sample", "Chopstick", "Take"]},
   {"handler": "leftTaken", "probe": "left", "answers": ["sample", "Chopstick", "Take"],
    "answerField": "hakker", "message": ["sample", "Chopstick", "Taken"], "replyTo": true}]}
```

`hears` checks that the next message the probe receives is a `Take`.
`answers` sends `Taken` to the address in the `Take` the probe heard last,
with the probe as the chopstick. `messageValue` sends the sample's `Think`
singleton.

The hakker's timers run on Pekko's
[`ManualTime`](https://pekko.apache.org/docs/pekko/current/typed/testing-async.html),
so they fire only when the model says time passes. The actor in
`acceptance/pekko-samples/fsm/hakkers.lawspec` has a line for it:

```lawspec fragment
actor hakker :: Diner by Seat is
  start openDiner by (startSeat ())
  on think by modelThink when waiting
  time passes by modelTimePasses when timerSet
  on asksLeft by modelAsksLeft when leftTake
  on leftTaken by modelLeftTaken when awaitsLeft
end actor
```

`modelTimePasses` returns how long passes, which is how long the hakker's
timer has left, and the state after it fires. LawSpec advances the virtual
clock by that much, then checks the probes hear what the model says. Its
laws hold of every run of the model:

```lawspec fragment
law "|a hakker eats only with both chopsticks| in model hakker is
  definition: every run holds always eatsWithBoth end definition
end law
```

The chopstick's own binding checks that it has one holder at a time. With
this law, two neighbours, who share a chopstick, never eat at once.
"Every hungry hakker eventually eats" is not true, even when every step is
fair. The chopsticks can answer so that the hakker always gets one, is
refused the other, puts it back and tries again. The sample's random
thinking times only make that unlikely. The suite's `starvation` spec
mutant states the law, and LawSpec refutes it with such a run.

## Bind a sharded entity: the weather station

In `pekko-sample-sharding-java`, a `WeatherStation` is a sharded entity: one
per station id, keeping its readings in memory. Give the binding the
entity's `EntityTypeKey`. Every handler then takes the station's id first:

```lawspec fragment
record :: Stations -> Text -> Int16 -> Pair Text Stations
readings :: Stations -> Text -> Pair Int32 Stations
```

```json
{"actor": "sample.killrweather.stations::stations",
 "behavior": ["sample", "killrweather", "WeatherStation", "create"],
 "entity": ["sample", "killrweather", "WeatherStation", "TypeKey"],
 "handlers": [
   {"handler": "readings",
    "messageFactory": ["sample", "killrweather", "StationMessages", "temperatures"],
    "replyTo": true, "reply": ["sample", "killrweather", "WeatherStation", "QueryResult"],
    "resultField": "readings"}]}
```

LawSpec starts a one-node Pekko Cluster in the test kit and runs the entity
under Cluster Sharding. It sends every message through the station's
`EntityRef`. The model keeps each station's readings apart, so a station
that shares its readings with another fails.

`WeatherStation`'s `Record` carries the sample's own `Data` class, which no
codec makes. `messageFactory` names a small static method in the sample's
package that makes the message from the handler's arguments instead.

## Run the suites

```sh
stack run lawspec-acceptance -- pekko-samples/persistence java
stack run lawspec-acceptance -- pekko-samples/fsm java
stack run lawspec-acceptance -- pekko-samples/fsm scala
stack run lawspec-acceptance -- pekko-samples/sharding java
```

Each suite runs the correct sample, then each mutant, and every mutant must
be caught.

## What LawSpec cannot check yet

- **Time on other runtimes.** `time passes` runs only on a Pekko behaviour
  with a native binding, on Java or Scala. Every other implementation, and
  a persistent or sharded Pekko actor, is reported unsupported. A parallel
  run never lets time pass.
- **The whole table.** The laws are stated of one hakker and one
  chopstick, each checked against its real behaviour. That neighbours never
  eat at once follows from the two. No model of the table of five is
  checked against the running sample.
- **Large protocol models.** The model checker explores each state whole.
  Partial-order reduction applies only to laws with no fairness or
  deadline, and there is no symmetry reduction, so identical parts, such as
  five hakkers at one table, are not explored as one.
- **Narrow command arguments.** A refinement that generation cannot read,
  such as a regular expression on a `Text`, does not guide it. The draws it
  rejects are counted, and a run of mostly rejected steps is incomplete.
- **Laws over unbounded models.** The cart's items and quantities have no
  bound, so a law over its runs is incomplete. That a checked-out cart stays
  checked out is checked against the real cart instead.
- **Application classes in messages.** Native type bindings expect Java
  records and public classes. A message carrying the application's own
  classes needs a `messageFactory`.
- **CQRS.** `pekko-sample-cqrs-java` has no code upstream: its README
  points to the Akka Platform Guide. Its last code is from Akka 2.6, before
  the fork, and uses Akka's packages and Cassandra. So there is no Pekko
  write side to bind, and no read side, nor projection, to check.
- **Reply cases.** `replyCases` reads a `Bool` or a `Text` from which class
  the reply is, as the Scala chopstick's `Taken` or `Busy`. Other result
  types need a `result` accessor.
