---
id: lawspec.how-to.vet
kind: how-to
title: Vet the canonical material
---
# Vet the canonical material

canon records every canonical comment, page, decision and reference in
`canonical_vetting/` as `pending` until a person judges it
ref:DEC-canonical-format. This guide judges them on Rice's Tax's review page
instead of editing YAML by hand ref:DEC-vet-with-rices-tax: you click a verdict,
the page writes it into the vetting file in your working tree, and you commit
it, so git records who signed.

## Set up once

Rice's Tax and canon must be one canon version: Rice's Tax 0.4.1 is built
against canon 0.2.1, which is the version `canon.yaml` names under `canon`.
Check out canon at that version and Rice's Tax beside it, where its
`stack.yaml` expects `../canon`, build both, and point the two variables at
them:

```sh
git clone https://github.com/brain-fuel/canon && (cd canon && stack build)
git clone https://github.com/brain-fuel/ricestax && (cd ricestax && stack build)
export CANON_HOME=$PWD/canon
export RICESTAX_HOME=$PWD/ricestax
stack run lawspec-dev -- canon version   # canon 0.2.1
```

`lawspec-dev tax` links `.canon` to `CANON_HOME`, as `lawspec-dev canon`
does, and refuses to run when the two checkouts are different canon versions.
Rice's Tax itself refuses a repository whose `canon.yaml` names another canon
than its own.

## 1. Assess

```sh
make assess
```

This records a `pending` row for every comment, page, decision and reference
that has none, as `canon ingest` does, and reports what canon counts as pending
and what is owed under `canonical_exemptions.yaml`. It also raises Rice's Tax's
What queue, a row per unit that needs a comment, which the `name` exemption
keeps out of this release's work. Run it again after you write or change
comments; a row whose text changed after its verdict is pending again.

## 2. Open the review page

```sh
make tax                 # http://localhost:8080; PORT=8091 make tax for another port
```

The server reads the whole repository through canon first, which takes about
ten seconds, then serves the page. The Why tab holds the comments, pages,
decisions and references; each card shows the comment with the code it
explains (or the page, the question and its answer, or the reference), what it
cites, and what canon finds on the row. Click **Good**, **Bad** or
**Deferred**, with a note when the verdict is bad and a version to revisit by
when it is deferred.

Most rows are under the directory exemptions of
`canonical_exemptions.yaml`, so they are listed under **Exempt**, grouped by
exemption, and counted as owed under exemptions. Either:

- press **Review** on a group to decide its rows as cards while the exemption
  stands, or
- choose a file or page in the subject list and press **Lift the exemption for
  this subject**: that file alone becomes due, and its directory's exemption is
  narrowed to the rest of the directory. **Lift** on a group lifts the whole
  exemption.

A lifted subject also makes its missing comments due, so `make canon` fails
until they are written or the subject is vetted. The page refuses a verdict on
a file that changed since it read the repository; press **re-read** first.

## 3. Review and commit

```sh
git diff canonical_vetting canonical_exemptions.yaml
git commit -am "Vet <what you vetted>"
```

The committer of a verdict line is its signer. A verdict that is saved but not
committed is reported as unsigned.

## 4. See what is left

```sh
make audit               # Rice's Tax: pending, owed under exemptions, unsigned
make canon               # canon check: the same pending set, as the release checks it
```

`make audit` prints canon's pending count and what is still owed under
exemptions, and fails while a row is pending outside an exemption, a verdict is
uncommitted, or an exemption has reached its revisit version. The two commands
count the same pending set. Vetting is deferred until 1.0: before 1.0.0 is
released, every exemption whose revisit is 1.0.0 must be lifted or extended,
since `make canon` fails once the version reaches it (see [the release guide](release.md)).
