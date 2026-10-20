---
id: lawspec.reference.language.linguist-eligibility
kind: reference
title: GitHub Linguist eligibility
---
# GitHub Linguist eligibility

GitHub highlighting remains an external pre-final-1.0 dependency. A local
`.gitattributes` override selects an installed language; it cannot install a
custom grammar. Native recognition requires upstream acceptance and deployment.

The repository provides an MIT-licensed TextMate grammar at
`editors/vscode/syntaxes/lawspec.tmLanguage.json`, generated from the matching
shared template. The extension registers `source.lawspec` for `.lawspec` files.
The documentation site interprets those same grammar bytes with the matching
TextMate and Oniguruma versions. Browser-bundle token scopes are checked against
the editor across the repository's specification corpus.
Tokenizer tests cover current examples, parser fixtures, comments, escapes,
Unicode identifiers and identifier boundaries. The RC1 sample is
`examples/rc1-authoring.lawspec`.

The upstream contribution would include a language registry entry, extension,
scope, grammar registration, representative licensed samples and usage evidence.
[Linguist's contribution requirements](https://github.com/github-linguist/linguist/blob/main/CONTRIBUTING.md)
require independent adoption evidence. That evidence has not been collected,
and no upstream submission, acceptance or deployment is claimed. Record those
steps in the single pre-1.0 review packet before removing the Haskell fallback.

Rechecked against upstream on 20 October 2026: `.lawspec` can occur repeatedly in
one repository. The applicable usage threshold is 2,000 indexed files from the
last year, excluding forks, with varied independent owners and repositories.
The separate 200-file threshold applies to names normally occurring once per
repository. Files in this repository do not establish that independent
adoption. See the current
[usage assessment](https://github.com/github-linguist/linguist/blob/main/CONTRIBUTING.md#language-extension-and-filename-usage-requirements).

Local preparation includes six passing tokenizer tests and compiled domain
examples, including authorization snapshots and checked codecs. Upstream
grammar import/compilation, registry registration, representative sample
selection and licensing review, and usage evidence remain outstanding. Local
Oniguruma tests do not establish acceptance by Linguist's grammar compiler.

The cross-project 1.0 programme retains this as an early, independent track.
Record candidate adoption with the repository URL, owner, licence, relevant
`.lawspec` paths, observation date and whether it is a fork or part of this
project family. Record the search query, observation date and manual sample of
independent repositories alongside any indexed-file count. No current search
count or qualifying independent-adoption inventory has been established here;
the requirement recheck does not satisfy eligibility. Grammar validation,
submission, acceptance and GitHub deployment each need separate receipts.
