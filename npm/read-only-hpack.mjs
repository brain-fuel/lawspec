#!/usr/bin/env node
// Generated from templates/npm/read-only-hpack.mjs by lawspec-dev generate. Do not edit.
import { readdirSync } from "node:fs";
if (process.argv.some((a) => a === "--numeric-version" || a === "--version"))
  console.log("0.38.1");
else if (!readdirSync(process.cwd()).some((f) => f.endsWith(".cabal"))) {
  console.error(
    "LawSpec doctor requires an existing .cabal file. Run stack build --test --no-run-tests first.",
  );
  process.exitCode = 1;
}
