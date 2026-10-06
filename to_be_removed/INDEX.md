# Records waiting for a canonical home

Nothing in this directory is authoritative. These are the local plan and
recovery notes kept before LawSpec adopted canon's canonical format in 0.20.1
(`DEC-canonical-format`). Each waits for what it says below; once every
decision in a file is in `canonical_decisions.yaml`, or recorded as not worth
keeping, the file is deleted.

| File | Waiting for |
| --- | --- |
| `PLAN-0.9.md` | Its remaining design notes (the 0.9 typed core, generation and output plans) to be folded into the ledger; the main decisions are in as `DEC-typed-core-boundary`, `DEC-portable-exact-arithmetic`, `DEC-planned-generation`, `DEC-readable-output-default` and others that cite it. |
| `ACCEPTANCE-0.9.md` | The acceptance criteria to become `requirement` entries cited by the acceptance suites' tests (`DEC-acceptance-with-mutants`). |
| `PLAN-0.11.md` | Folded as `DEC-abstract-integer-at-boundaries`, `DEC-elaborate-before-core` and the entries that cite it; to be reviewed in the 0.20.2 vetting, then deleted. |
| `PLAN-0.12.md` | As above, for the 0.12 decisions. |
| `PLAN-0.13.md` | As above, for the 0.13 decisions. |
| `PLAN-0.14.md` | As above, for the 0.14 decisions. |
| `PLAN-0.16.md` | As above, for the 0.16 decisions. |
| `PLAN-0.17.md` | As above, for the incremental compilation decisions (`DEC-incremental-compilation`). |
| `RECOVERY.md` | Its policy is `DEC-recovery-not-regeneration`; the rest is a narrative of one recovery, to be deleted after the 0.20.2 vetting. |
