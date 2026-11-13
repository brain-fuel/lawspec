---
id: lawspec.how-to.validate-and-mask-records
kind: how-to
title: Validate and mask a record
---
# Validate and mask a record

Use this when an application receives a record from outside (a form, a
request body) and must report everything wrong with it at once, without
writing personal data to its logs.

## 1. Write the rules on the record

Restrict each field where it is declared. Give a restriction a name with
`as` when its default id would not tell a caller enough, and add a `rule`
for a condition over several fields.

```lawspec
unit guide.orders

type Order is a record{
  reference :: (v :: Text where v matches regex "[A-Z]{3}-[0-9]{6}" as shape),
  buyer :: (v :: Text where v matches format email),
  quantity :: (v :: Int32 where 1 <= v && v <= 999),
  giftNote :: Text,
  gift :: Bool}
  rule noteForGift is gift || giftNote == ""
end type

masking Order is
  buyer shown as email
  giftNote shown as hidden
end masking

function order (u :: Unit) -> OrderDraft is
  OrderDraft record{reference = "ABC-000123", buyer = "ann@example.org",
    quantity = 2, giftNote = "", gift = false}
end function

law "|a note needs a gift| is
  definition :
    validateOrder (order () with giftNote = "Happy birthday") fails with noteForGift
  end definition
end law

law "|a wrong quantity and a wrong reference are both reported| is
  definition :
    prelude.violatedRules
      (violationsOfOrder (order () with quantity = 0, reference = "abc"))
      = ["reference.shape", "quantity.min"]
  end definition
end law

law "|an order is logged without the buyer's address| is
  definition :
    maskedOrderDraft (order ())
      = "Order{reference=ABC-000123, buyer=a***@example.org, quantity=2, giftNote=***, gift=false}"
  end definition
end law
end unit
```

Naming `validateOrder`, `violationsOfOrder` or `OrderDraft` is what makes
LawSpec generate them. A rule of the whole record, `noteForGift` here, needs
an example that ends `fails with noteForGift`; LawSpec refuses the record
without one, because it cannot generate a value that breaks only that rule.

## 2. Run the checks

```sh
lawspec test
```

Beside the unit's own laws this runs one generated law per field rule (`Order
reports quantity.min alone`, and so on), `Order passes its own validator`,
and one law per masked field. A guarded law that no generated case reached
is reported as `vacuous`, not as passed.

## 3. Call the validator from the application

The generated definitions are ordinary functions of the target. In Java:

```java
var result = lawspec.definitions.guide.Orders.validateOrder(Map.of(), draft);
```

`result` holds the `Order` or the list of `Violation`s, each with the rule's
id, the field and a message. Map ids to the application's own wording by id;
the message is a default for logs and developers, and it shows a masked
field's value through its mask.

## 4. Log the masked rendering

On Java, JavaScript, TypeScript and Python a record with a masking block
renders itself masked: `log.info("placed {}", order)`, `console.log(order)`
and `logger.info("placed %s", order)` print what the block allows. The real
text is behind an explicit name, `toUnmaskedString()` or `unmasked_repr()`.
Field access and serialisation are not masked.

On any other target, pass `maskedOrder(order)` or `maskedOrderDraft(draft)`
to the logger, not the record; generation warns that the native rendering
there shows every field.

A field `shown as hash` needs a key before the first rendering. Set it when
the application starts, for example in Java:

```java
lawspec.runtime.LawSpecMasks.setHashKey(secrets.maskingKey());
```

`secrets.maskingKey()` stands for your own source of 32 secret bytes.
Without a key the rendering throws.

See [record rules, validators and masking](../reference/language/record-rules.md)
for every id, mask and limit.
