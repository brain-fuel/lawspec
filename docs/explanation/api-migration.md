---
id: lawspec.explanation.api-migration
kind: explanation
title: Pre-1.0 API changes
---
# Pre-1.0 API changes

LawSpec does not provide migration tooling or compatibility grammars before a
stable API. Version 0.26 removes the earlier migration command and API methods.
Update source and consumers directly to the [current grammar](../reference/language/syntax.md).

Requests use API schema 5 and language profile `1.0-rc.2`. Components and contract packages use
version 1 `lawspec.edn` manifests and the same profile. Law verification layers remain
explicit; mandatory definition validation always runs.

## Source migration from 0.24

The former pre-1.0 migration feature is retired. Earlier release notes and
review receipts describe its historical behavior. It is not available in the
current CLI or SDK.
