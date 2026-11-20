-- | lawspec reference: the references the LawSpec skills read (the authoring
-- guide, the compiler inventory, the library reference, the reusable law
-- source and the course), printed from the package resources the host
-- ships. The skills keep only their SKILL.md, so the references always come
-- from the compiler the project runs. ref:DEC-prelude-first-authoring
module LawSpec.App.Reference
  ( referenceCommand,
    referenceNames,
  )
where

import Data.List (intercalate)
import LawSpec.App.Command
import LawSpec.Host.Effect
import LawSpec.Host.Path (join)

-- | The references, by the name lawspec reference takes.
referenceNames :: [String]
referenceNames = ["authoring.md", "library.json", "library.md", "prelude.lawspec", "curriculum.json"]

referenceCommand :: (Monad m) => Maybe FilePath -> [String] -> Command m Int
referenceCommand resources positionals = case positionals of
  [] -> 0 <$ printLine (intercalate "\n" referenceNames)
  [name]
    | name `elem` referenceNames -> do
        directory <- maybe (failWith missing) pure resources
        let file = join (join directory "references") name
        grantRead [file]
        bytes <- effectOr (ReadFile file) >>= either (const (failWith missing)) pure
        0 <$ writeOutput Stdout bytes
  _ -> failWith ("Usage: lawspec reference [" ++ intercalate "|" referenceNames ++ "]")
  where
    missing = "The skill references ship in the lawspec npm package; this host has none. Install it with npm install --save-dev lawspec, or in a compiler checkout run lawspec-dev generate."
