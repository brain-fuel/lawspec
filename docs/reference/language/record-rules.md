---
id: lawspec.reference.language.record-rules
kind: reference
title: Record rules, validators and masking
---
# Record rules, validators and masking

A record's rules are the restrictions its fields carry and its named rules of
the whole record. Each rule has a stable id. From them LawSpec generates a
validator that reports every rule a value breaks, laws that check it, and,
for a record with a `masking` block, a rendering that hides what the block
says to hide. There is no separate contract declaration: the record is the
contract.

```lawspec
unit guide.signup

function validName (name :: Text) -> Bool is
  name matches regex "[A-Za-z][A-Za-z '-]{0,63}"
end function

type Signup is a record{
  name :: (v :: Text where validName v),
  email :: (v :: Text where v matches format email),
  age :: (v :: Int32 where 18 <= v && v <= 120),
  plan :: (v :: Text where v in ["free", "pro"]),
  code :: (v :: Text where
    v matches regex "[A-Z]{2}[0-9]{2,8}" as shape && prelude.length v <= 6),
  vatId :: Text}
  rule vatForPro is plan != "pro" || vatId != ""
end type

function ann (u :: Unit) -> SignupDraft is
  SignupDraft record{name = "Ann Lee", email = "ann@example.org", age = 30,
    plan = "pro", code = "GB1234", vatId = "GB123456"}
end function

law "|each broken rule is named| is
  definition :
    validateSignup (ann () with age = 17) fails with age.min
    and validateSignup (ann () with code = "gb1234") fails with code.shape
    and validateSignup (ann () with vatId = "") fails with vatForPro
  end definition
end law

law "|every broken rule is reported, in order| is
  definition :
    prelude.violatedRules
      (violationsOfSignup (ann () with age = 17, plan = "gold"))
      = ["age.min", "plan.oneOf"]
  end definition
end law
end unit
```

## Rule ids

A field's restriction is split at `&&`; each part is one rule, with the id
`<field>.<suffix>`.

| Restriction | Suffix | Message |
| --- | --- | --- |
| `n <= v`, `v > n` | `min` | must be at least `n`, must be greater than `n` |
| `v <= n`, `v < n` | `max` | must be at most `n`, must be less than `n` |
| `v == e`, `v != e` | `equals`, `notEquals` | must be `e`, must not be `e` |
| `prelude.length v >= n`, `<= n`, `== n` | `minLength`, `maxLength`, `length` | must have at least `n` characters (items, for a list) |
| `v matches regex "p"` | `pattern` | must match the regex `"p"` |
| `v matches format email`, `uuid` | `email`, `uuid` | must be an RFC 822 address, a UUID |
| `v in [a, b]` | `oneOf` | must be one of `[a, b]` |
| `check v` (a definition of the unit) | the definition's name | must satisfy `check` |
| a list's or optional's item restriction | `items`, `payload` | |

`as <name>` after a part gives it that suffix instead, and is required when
two parts of one field would share an id. `rule <name> is <condition>`, after
the record's closing brace, is a rule of the whole record; its id is its
name, and its condition reads the fields by name.

An id is made of names only, so reordering fields or rules keeps it, and
renaming a field or a rule changes it visibly. A restriction whose shape has
no suffix (a disjunction, say) is refused until it is given one with `as`.

## What is generated

Naming one of these in any source of the program generates all of them for
the record `R`; a record nobody validates costs nothing.

| Name | Type | Meaning |
| --- | --- | --- |
| `RDraft` | a record | `R`'s fields at their unrestricted types |
| `violationsOfR` | `RDraft -> List Violation` | every rule the draft breaks, in declaration order |
| `validateR` | `RDraft -> Either (List Violation) R` | the record, or those violations |
| `draftOfR` | `R -> RDraft` | a record's draft |

`Violation` is `record{rule :: Text, field :: Maybe Text, message :: Text}`
from the built-in unit `lawspec.rules`, which joins a program that uses
rules. `field` is `Absent` for a rule of the whole record. A message for a
text, integer or Boolean field ends `, but was <value>`.

`e fails with <rule id>` holds when the validation `e` failed with exactly
that rule. `prelude.violatedRules vs` gives the ids of a list of violations.

These are ordinary checked definitions, compiled for every target like the
unit's own. `validateR` builds `R` under one condition per rule, so the
totality audit proves that the record it returns meets every restriction; a
validator that could let a broken value through is rejected at compile time.

## Generated laws

- `R passes its own validator`: for every `R`, `validateR (draftOfR r)` is
  `Right r`.
- `R reports <id> alone`, for each field rule: a draft made from a valid `R`
  by replacing the field with a value that breaks only that rule fails with
  exactly that id. The law is guarded, so its reach is counted: a rule that
  no generated value breaks alone makes the law `vacuous`, not passed
  ([laws and examples](laws-and-examples.md)). The law is left out when the
  unit already has an example ending `fails with <id>`.
- A rule of the whole record has no generated law, because no draft that
  breaks it alone can be built from its shape. The unit must give an example
  ending `fails with <id>`; without one the record is refused.

## Formats

`matches format <name>` restricts a text to a named format. A format is a
regex of the [portable dialect](matchers.md), so every target checks it with
the matcher it already has and generation draws matching texts from it.

| Format | Accepts |
| --- | --- |
| `email` | an `address` of RFC 822, section 6.1: `ann@example.org`, `Ann Lee <ann@example.org>`, a routed address, a group (`team: a@x.example, b@y.example;`) |
| `uuid` | 32 hexadecimal digits in groups of 8-4-4-4-12, in either case |

`email` accepts exactly the texts the regex of the Perl module
Mail::RFC822::Address 0.3 accepts. That is wider than a mailbox: it includes
display names, routes and groups, quoted local parts, domain literals,
domains of one label and one final line feed. A comment (`ann@example.org
(Ann)`) is refused: the module's `valid` function removes comments before it
matches, and the format does not, because nested comments are not regular.
The agreement is tested against the module, not proved; the recorded
verdicts are in `test/fixtures/formats/email-vectors.tsv`.

## Masking

```lawspec
unit guide.cards

type Card is a record{
  holder :: (v :: Text where prelude.length v >= 1),
  number :: (v :: Text where v matches regex "[0-9]{13,19}"),
  contact :: (v :: Text where v matches format email),
  pin :: Int32}
end type

masking Card is
  holder shown as hidden
  number shown as last 4
  contact shown as email
  pin shown as hidden
end masking

function sample (u :: Unit) -> CardDraft is
  CardDraft record{holder = "Ann Lee", number = "4111111111111111",
    contact = "ann@example.org", pin = 1234}
end function

law "|a card is shown masked| is
  definition :
    maskedCardDraft (sample ())
      = "Card{holder=***, number=***1111, contact=a***@example.org, pin=***}"
  end definition
end law
end unit
```

| Mask | Shows |
| --- | --- |
| `hidden` | `***` |
| `last <n>` | `***` and the last `n` characters; `***` alone for a text of `n` characters or fewer |
| `email` | the first character, `***` and everything from the last `@`; `***` alone for a text without `@` |
| `hash` | `hash:` and a keyed BLAKE3 digest in a native rendering; `***` in `maskedR` and in messages ([below](#the-hash-mask)) |

A masking block generates `maskedR :: R -> Text` and `maskedRDraft ::
RDraft -> Text`, and violation messages show a masked field's value through
its mask. Only a `Text` field takes `last`, `email` or `hash`.

For each masked field LawSpec generates a law. `R masks <field>`: a marker
placed in the part of the field the mask hides appears in no rendering and
no violation message. `R hides <field>`, for a hidden field that is not a
text: two drafts that differ only in it render alike.

### Where a masked field is hidden

| Rendering | Java | JavaScript, TypeScript | Python | Other targets |
| --- | --- | --- | --- | --- |
| `maskedR`, `maskedRDraft`, violation messages | masked | masked | masked | masked |
| The record's own text form | `toString()` | `toString()`, `util.inspect` and so `console.log` | `repr()`, `str()` | **not masked** |
| Output of a failed generated test | `***` | `***` | `***` | **not masked** |
| A logger given the record | masked, through `toString()` | masked | masked | **not masked** |
| The unmasked text, by an explicit name | `toUnmaskedString()` | `toUnmaskedString()` | `unmasked_repr()` | |
| Fields, accessors and wire forms | not masked | not masked | not masked | not masked |

"Wire forms" are what a program sends or stores: Java's record accessors
and whatever serialises through them, `JSON.stringify`
and property access in JavaScript and TypeScript, `dataclasses.asdict` and
attribute access in Python. They carry the real values, because a masked
value cannot be read back. JavaScript classes define no `toJSON` for that
reason.

On a target of the last column, generation warns with `target-unsupported`
for each record with a masking block. `maskedR` works there; nothing else
is masked.

The output of a failed generated test shows `***` for every masked field,
whatever its mask, and two records that differ only in masked fields are
reported as "the values differ only in masked fields". A failure is
replayed from its seed. Where a target keeps a failure database (Python's
`LAWSPEC_FAILURES/inputs`, for one), it stores the failing inputs
themselves, unmasked, so that it can replay them: treat that directory as
you treat test data.

A debugger, a heap dump and reflection read the fields, not the rendering.
Masking is a default for text people and logs read; it is not access
control.

### The hash mask

`shown as hash` shows `hash:` and the 64 hexadecimal digits of the keyed
BLAKE3-256 digest of the text's UTF-8 bytes. Equal values show the same
digest, so a log can be searched for one value without holding it, and the
value cannot be recovered without the key.

The key is 32 secret bytes. The application sets it once, when it starts,
from wherever it keeps secrets:

| Target | Call |
| --- | --- |
| Java | `lawspec.runtime.LawSpecMasks.setHashKey(byte[] key)` |
| JavaScript, TypeScript | `setMaskKey(key: Uint8Array)` of `lawspec_runtime` |
| Python | `lawspec_runtime.set_mask_key(key: bytes)` |

LawSpec never writes a key into generated code and has no default key. A
rendering asked for before the key is set throws (`IllegalStateException`,
`Error`, `RuntimeError`); it never shows the value and never falls back to
`***`. Set the key before the first log line.

`maskedR`, violation messages and failed-test output show `***` for a
hashed field: a checked definition is pure and has no key. Other targets
have no keyed digest; there the field is hidden by `maskedR` and the
generation warning says so.

The three runtimes' digests are tested against LawSpec's Haskell port of
BLAKE3 on texts that cross block, chunk and tree boundaries
(`test/fixtures/blake3-keyed-text.json`). That port's unkeyed mode is
tested against BLAKE3's published vectors. The repository holds no copy of
the published keyed vectors, so the keyed mode is checked against the port
only.

### Logging in Java

A record with a masking block renders itself masked, so
`log.info("placed {}", order)` is already safe. Two more pieces cover what
`toString()` cannot:

- `lawspec.runtime.LawSpecMasked.of(value)` wraps a logging argument. An
  array of records is rendered element by element instead of as a type and
  an address, and nothing is rendered when the level is off. It needs no
  logging library and is always generated beside a masked record.
- `lawspec.logging.LawSpecMaskedConverter` is a Logback converter that
  renders every argument of a message that way. Use it in place of `%msg`.

The converter needs Logback and SLF4J, which a project may not have. So it
is generated outside the compiled sources, in `lawspec-logback/` beside the
build file, and a project that has no Logback compiles as before. To enable
it, add that directory as a source root (in Maven, a
`build-helper-maven-plugin` `add-source` execution naming `lawspec-logback`)
and register the converter:

```xml
<conversionRule conversionWord="maskedMsg"
    converterClass="lawspec.logging.LawSpecMaskedConverter" />
<pattern>%d %-5level %logger - %maskedMsg%n</pattern>
```

`init` and `doctor` neither add nor check this: there is no manifest option
for it. Log4j 2 has no converter yet; with Log4j 2, rely on `toString()`
and `LawSpecMasked.of`.

## Limits

- A field whose type is a named refinement, and a record with type
  parameters, are refused by the validator generator.
- Native renderings, failed-test output and the hash digest are masked on
  Java, JavaScript, TypeScript and Python only
  ([above](#where-a-masked-field-is-hidden)). Those four are the targets
  the `contracts-validation` and `contracts-masking` suites run on; no
  other target has run them.
- A masked field inside a message your own code builds (string
  concatenation of `order.number()`, say) is not masked: the mask is on the
  record's rendering, not on the value.
- JSON Schema output writes `pattern`, `minLength`, `maxLength`, `minItems`,
  `maxItems`, `enum` and numeric bounds; a rule it cannot express, such as a
  rule of the whole record, is refused as `target-unsupported`
  ([artifact targets](../artifact-targets.md)). A masked field is marked
  `"x-lawspec-masking": "hidden" | "last <n>" | "email" | "hash"`.
