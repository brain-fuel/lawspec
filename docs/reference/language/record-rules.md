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
| `v matches format email`, `rfc822Address`, `uuid` | `email`, `rfc822Address`, `uuid` | must be an email address, an RFC 822 address, a UUID |
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

`matches format <name>` restricts a text to a named format. A format is one
rule, whatever it checks, and generation draws matching texts from it.

| Format | Accepts | Targets |
| --- | --- | --- |
| `email` | one mailbox in ASCII: `ann@example.org`, `"Ann Lee"@example.org`, `ann@[10.0.0.1]`. A domain name has at least two labels. At most 64 characters before the `@` and 254 in all | all |
| `rfc822Address` | an `address` of RFC 822, section 6.1, comments included: `ann@example.org (Ann Lee)`, `Ann Lee <ann@example.org>`, a routed address, a group (`team: a@x.example, b@y.example;`), `ann@localhost` | Java, JavaScript, TypeScript, Python |
| `uuid` | 32 hexadecimal digits in groups of 8-4-4-4-12, in either case | all |

Use `email` for an address a person types. It accepts nothing that
Email::Valid 1.204 refuses (with `fqdn` on and its network checks off), and
it is narrower than that module in six listed ways: no comment, no display
name, no white space, no control character, no loose IP literal and no
quoted string beside other words. Its two length limits are part of the
rule `<field>.email`, not rules of their own.

Use `rfc822Address` where a text must be accepted exactly when RFC 822
allows it, a mail header for one. It accepts exactly the texts `valid()` of
the Perl module Mail::RFC822::Address 0.3 accepts. Comments are removed
before the match, which needs a runtime primitive; a program that uses the
format on a target without it is refused with `target-unsupported`.

[What each accepts, side by side](matchers.md#what-the-address-formats-accept)
lists the differences and every deviation from Email::Valid. Both
agreements are tested against recorded verdicts of the modules
(`test/fixtures/formats/`), not proved.

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

| Mask | Shows | Needs a key | The mask as a function |
| --- | --- | --- | --- |
| `hidden` | `***` | no | `maskStar` |
| `last <n>` | `***` and the last `n` characters; `***` alone for a text of `n` characters or fewer | no | `maskLast` |
| `email` | the first character, `***` and everything from the last `@`; `***` alone for a text without `@` | no | `maskEmail` |
| `digest` | `digest:` and a hash of the value by this version's default algorithm, BLAKE3 ([below](#the-digest-mask)) | no | `maskDigestIn` |
| `digest blake3` | the same, with the algorithm named | no | `maskDigestBlake3In` |
| `hash` | `hash:` and a hash of the value under a secret key, by the default algorithm ([below](#the-hash-mask)) | yes | `maskHash` |
| `hash blake3` | the same, with the algorithm named | yes | `maskHashBlake3` |

A masking block generates `maskedR :: R -> Text` and `maskedRDraft ::
RDraft -> Text`, and violation messages show a masked field's value through
its mask. Only a `Text` field takes `last`, `email`, `digest` or `hash`.

### Which mask to choose

| You want | Write | Because |
| --- | --- | --- |
| Nothing of the value shown | `hidden` | nothing can be learnt from `***` |
| The end or the domain recognisable to a person | `last <n>`, `email` | part of the value is shown as it is |
| Equal values to line up in a log, with no key to manage, for a value nobody can guess | `digest` | works in every rendering and on every target |
| Equal values to line up, for a value somebody could guess | `hash` | without the key a guess cannot be checked |

**A digest hides a value from a reader. It does not hide it from someone
who can guess it.** A digest takes no key, so anyone can hash a candidate
and compare. A long random token is safe behind a digest; a card number, a
telephone number, a date of birth, a postcode, a name or an email address is
not, because the candidates can all be tried. For those use `hash`, which
needs the key to test a guess, or `hidden`.

LawSpec reports the cases it can see. Where the restriction written on a
digest field allows at most 2^64 values, `lawspec advise` reports the rule
`enumerable-digest` and generation gives the same text as a warning; nothing
is refused. The count is the least of what the parts of the restriction
give: a regex by its shape (`[0-9]{13,19}` allows about 2^63), `v in [...]`
by its length, `prelude.length v <= n` by the texts of that length, and `v
== "..."` one. 2^64 is the threshold because searches of that size have been
carried out in public. No report does not mean the field is safe: LawSpec
does not know that an unrestricted `Text` holds a surname.

### The masks as functions

Each mask is a function with one name everywhere, in the casing of the
language it is called from.

| | LawSpec | Java (`lawspec.runtime.LawSpecMasks`) | JavaScript, TypeScript (`lawspec_runtime`) | Python (`lawspec_runtime`) |
| --- | --- | --- | --- | --- |
| Nothing shown | `prelude.maskStar text` | `maskStar(value)` | `maskStar(value)` | `mask_star(value)` |
| The last characters | `prelude.maskLast n text` | `maskLast(n, text)` | `maskLast(n, text)` | `mask_last(n, text)` |
| An address | `prelude.maskEmail text` | `maskEmail(text)` | `maskEmail(text)` | `mask_email(text)` |
| A digest | `prelude.maskDigest text` | `maskDigest(text)` | `maskDigest(text)` | `mask_digest(text)` |
| A digest within a context | `prelude.maskDigestIn context text` | `maskDigestIn(context, text)` | `maskDigestIn(context, text)` | `mask_digest_in(context, text)` |
| A hash under the configured key | | `maskHash(text)` | `maskHash(text)` | `mask_hash(text)` |
| A hash under a key given with the call | `prelude.maskHash key text` | `maskHashWith(key, text)` | `maskHashWith(key, text)` | `mask_hash_with(key, text)` |

Each digest and hash function has a second name that says the algorithm:
`maskDigestBlake3`, `maskDigestBlake3In`, `maskHashBlake3` and
`maskHashBlake3With` (`mask_digest_blake3` and so on in Python). In this
version the two names are one function. A later version may change which
algorithm the short names, `shown as digest` and `shown as hash` mean, and
will say so as a breaking change, because the values in old logs would stop
matching new ones. Write the name with `Blake3`, and `shown as digest
blake3` or `shown as hash blake3`, where values must stay comparable across
versions.

Every mask is a checked LawSpec definition and works on every target. A
runtime function ending `With` takes its key with the call; `maskHash(text)`
without it exists in the runtimes only, where an application has set a key.

The digests and hashes are built from four functions a specification can
also call directly:

| Function | Type | Gives |
| --- | --- | --- |
| `prelude.blake3 bytes` | `Bytes -> Bytes` | the 32-byte BLAKE3 hash |
| `prelude.blake3Keyed key bytes` | `Bytes -> Bytes -> Bytes` | the keyed hash; `key` must be shown to have 32 bytes |
| `prelude.blake3DeriveKey context bytes` | `Text -> Bytes -> Bytes` | BLAKE3's key derivation: 32 bytes from `bytes`, specific to `context` |
| `prelude.hex bytes` | `Bytes -> Text` | two lowercase hexadecimal digits for each byte |

For each masked field LawSpec generates a law. `R masks <field>`: a marker
placed in the part of the field the mask hides appears in no rendering and
no violation message. `R hides <field>`, for a hidden field that is not a
text: two drafts that differ only in it render alike.

### Where a masked field is hidden

| Rendering | Java | JavaScript, TypeScript | Python | Other targets |
| --- | --- | --- | --- | --- |
| `maskedR`, `maskedRDraft`, violation messages | masked | masked | masked | masked |
| The record's own text form | `toString()` | `toString()`, `util.inspect` and so `console.log` | `repr()`, `str()` | **not masked** |
| Output of a failed generated test | a digest field as its digest, any other masked field as `***` | the same | the same | **not masked** |
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
for each record with a masking block. `maskedR` works there, digests and
all; nothing else is masked.

The output of a failed generated test shows a digest field as its digest
and `***` for every other masked field, whatever its mask, and two records
that differ only in masked fields are reported as "the values differ only
in masked fields". A failure is replayed from its seed. Where a target
keeps a failure database (Python's `LAWSPEC_FAILURES/inputs`, for one), it
stores the failing inputs themselves, unmasked, so that it can replay them:
treat that directory as you treat test data.

A debugger, a heap dump and reflection read the fields, not the rendering.
Masking is a default for text people and logs read; it is not access
control.

### The digest mask

`shown as digest` shows `digest:` and 64 hexadecimal digits: a BLAKE3 hash
of the value. It takes no key, so it is the same in every rendering: the
record's own text form, `maskedR`, a violation's message and the output of
a failed test all show the digest, on every target that renders them
masked. Equal values of one field show the same digest, so a log can be
searched for a value without holding it. Read [which mask to
choose](#which-mask-to-choose) before using it on personal data.

```lawspec
unit guide.accounts

type Account is a record{
  owner :: Text,
  apiToken :: Text}
end type

masking Account is
  apiToken shown as digest
end masking

law "|a text's digest is its BLAKE3 hash| is
  definition :
    prelude.maskDigest "abc"
      = "digest:6437b3ac38465133ffb63b75273a8db548c558465d79db03fd359c6cd5bd9d85"
  end definition
end law

law "|an account shows its token's digest within the field's context| is
  definition :
    for all (account :: Account) =>
      maskedAccount account
        = "Account{owner=" ++ account.owner ++ ", apiToken="
          ++ prelude.maskDigestIn "guide.accounts.Account.apiToken" account.apiToken ++ "}"
    end for all
  end definition
end law
end unit
```

There are two digests.

- `maskDigest text` is `digest:` and the hexadecimal BLAKE3-256 hash of the
  text's UTF-8 bytes, with nothing added. `printf abc | b3sum` prints the
  same digits.
- `maskDigestIn context text` is the digest within a context: `digest:` and
  the hexadecimal of BLAKE3's key derivation (`derive_key`) with the context
  string `lawspec 0.34 mask <context>` and the text's UTF-8 bytes as the key
  material. `printf abc | b3sum --derive-key "lawspec 0.34 mask <context>"`
  prints the same digits.

A field of a masking block uses the second, with the context
`<unit>.<Record>.<field>`: the `apiToken` above is shown as `maskDigestIn
"guide.accounts.Account.apiToken"` of its value. A draft uses its record's
context, so `maskedAccountDraft` shows the same digest. The context keeps
fields apart: one text in two fields, or in the same field of two records,
shows two unrelated digests, so a reader cannot tell that an account's
token is also somebody's order reference. Renaming the unit, the record or
the field changes the field's digests. The `0.34` in the context string is
part of the construction and does not follow LawSpec's version.

The context separates fields. It is not a secret and adds no protection
against guessing: the context is in the generated code.

### The hash mask

`shown as hash` shows `hash:` and the 64 hexadecimal digits of the keyed
BLAKE3-256 hash of the text's UTF-8 bytes. `shown as hash blake3` is the
same with the algorithm named. Equal values show the same hash, so a log
can be searched for one value without holding it, and without the key a
guess at the value cannot be checked.

The key is 32 secret bytes. Where it comes from depends on who renders:

| Rendering | Key | A hashed field shows |
| --- | --- | --- |
| The record's own text form on Java, JavaScript, TypeScript and Python (`toString()`, `repr()`, a logger) | the one the application set | its hash; an exception if no key is set |
| The runtime's `maskHash(text)` | the one the application set | the hash; an exception if no key is set |
| `maskedRWith key r`, `maskedRDraftWith key draft` | given with the call | its hash |
| `prelude.maskHash key text`, the runtime's `maskHashWith(key, text)` | given with the call | the hash |
| `maskedR r`, `maskedRDraft draft` | none | `***` |
| A violation's message | none | `***` |
| Output of a failed generated test | none | `***` |

A checked definition is pure, so it cannot read a key the application set:
in a specification the key is an argument. `maskedRWith` and
`maskedRDraftWith` are generated for every masked record of a program that
names one of them, on every target. Their key is typed `(key :: Bytes where
prelude.length key = 32)`, so a caller must show that its key has 32 bytes,
and under the same key they give exactly the record's own text form. A name
ending `With` always means "under the key given here".

Because those names are generated, two records named `Order` and
`OrderWith` would both need `maskedOrderWith`. A program with both is
refused, with the two records named; rename one.

```lawspec
unit guide.sessions

type Session is a record{
  user :: Text,
  token :: Text}
end type

masking Session is
  token shown as hash
end masking

function fingerprint (key :: (k :: Bytes where prelude.length k = 32)) (token :: Text) -> Text is
  prelude.maskHash key token
end function

law "|a session shows its token's hash under the key| is
  definition :
    for all (key :: Bytes where prelude.length key = 32) (session :: Session) =>
      maskedSessionWith key session
        = "Session{user=" ++ session.user ++ ", token=" ++ fingerprint key session.token ++ "}"
    end for all
  end definition
end law
end unit
```

The application sets its key once, when it starts, from wherever it keeps
secrets:

| Target | Call |
| --- | --- |
| Java | `lawspec.runtime.LawSpecMasks.setMaskHashKey(byte[] key)` |
| JavaScript, TypeScript | `setMaskHashKey(key: Uint8Array)` of `lawspec_runtime` |
| Python | `lawspec_runtime.set_mask_hash_key(key: bytes)` |

LawSpec never writes a key into generated code and has no default key. A
rendering asked for before the key is set throws (`IllegalStateException`,
`Error`, `RuntimeError`); it never shows the value and never falls back to
`***`. Set the key before the first log line. Only those four targets hold
a configured key; elsewhere use `maskedRWith`.

### Text and bytes

A text is hashed as its UTF-8 bytes. Within a specification a text is a
sequence of Unicode scalar values, so every text has UTF-8 bytes. A Java or
JavaScript string can also hold half of a surrogate pair, which UTF-8
cannot; the runtime functions of the table above hash such a half as
U+FFFD.

### BLAKE3 on each target

Every target has BLAKE3 in its three modes (hash, keyed hash, key
derivation), single-threaded and without SIMD. Go uses the module
`goforge.dev/blake3sum`, which `lawspec init` adds to `go.mod` and which a
program that hashes imports through the generated file
`lawspec_blake3.go`. Every other target's LawSpec runtime carries its own
implementation, written from the BLAKE3 specification, and adds no
dependency. Each is checked against BLAKE3's official test vectors, all 35
inputs in all three modes, by the acceptance suite `contracts-digest`.
[Compatibility](../compatibility.md#record-rules-and-masking) says where
that suite has run.
