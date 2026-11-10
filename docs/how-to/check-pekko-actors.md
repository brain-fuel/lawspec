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

The checks run on Java. The field-by-field contract is in the
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
function modelAddItem (item :: Text) (quantity :: Int32)
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

## State laws over a protocol: the dining hakkers

A sample's `Hakker` is driven by its own timers and answers no message, so
it cannot be bound as an actor. State its protocol as a
[model](../reference/language/models.md) instead. A hungry hakker asks for
both chopsticks. With both, it eats. With one, it puts that one back and
thinks again. In `acceptance/pekko-samples/fsm/hakkers.lawspec`, the model's
adapters run this protocol against the sample's real chopsticks. Its laws
hold of every run of the model:

```lawspec fragment
law "|neighbours never eat at once| in model table is
  definition: every run holds always neighboursApart end definition
end law

law "|no deadlock| in model table is
  definition: every run holds always someoneCanStep end definition
end law
```

Both are proved over all 247 states of a table of three. "Every hungry
hakker eventually eats" is not true of this protocol, even under fairness.
Hakkers can deny one another for ever: each takes one chopstick, is refused
the other, puts it back and tries again. The sample's random thinking times
only make that unlikely. The suite's `starvation` spec mutant states the
law, and LawSpec refutes it with such a run.

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
stack run lawspec-acceptance -- pekko-samples/sharding java
```

Each suite runs the correct sample, then each mutant, and every mutant must
be caught.

## What LawSpec cannot check yet

- **Actors with no replies.** An actor observed only through the messages it
  sends to others, such as the sample's `Hakker`, has no binding. Neither
  has an actor driven by its own timers. Its protocol can only be restated
  as a model.
- **Large protocol models.** The model checker evaluates references
  slowly: the sample's table of five hakkers has 9,864 states and takes
  minutes, so the suite seats three.
- **Fairness per hakker.** `assuming fairness for c` is per command, not per
  argument. A model law's references must be total, so a hakker that cannot
  move takes a step that changes nothing, which also satisfies fairness.
- **Narrow command arguments.** A model generates each command's arguments
  from its adapter's types, with integer bounds from the adapter's
  preconditions. A refinement on a reference's argument, such as a regular
  expression on a `Text`, does not guide generation. A step whose arguments
  the reference rejects is skipped. So the cart's item names are any text.
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
- **Scala samples.** The Scala persistence and sharding samples are checked
  as the Java ones are, with the same specs. The Scala fsm sample is not: its
  chopstick answers with two case classes, `Taken` or `Busy`, and no
  accessor says which, so a binding cannot read `take`'s `Bool` from the
  reply yet.
