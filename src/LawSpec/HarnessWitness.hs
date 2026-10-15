-- | Bind harness witnesses to expanded lexical scopes, before specialization.
-- The proposition itself is unchanged; these are search choices only.
module LawSpec.HarnessWitness (prepareHarnessWitnesses) where

import LawSpec.Model
import Control.Monad (forM, unless)
import Data.List (intercalate, nub)

prepareHarnessWitnesses :: [Unit] -> [Expanded] -> Either [Diagnostic] [Unit]
prepareHarnessWitnesses units properties = forM units $ \u -> do
  plans <- forM (lawHarness u) $ \(name, plan) -> do
    choices <- if null (planWitnesses plan) then pure [] else case
      [p | p <- properties, owner p == unitName u, LawSpec.Model.name p == name] of
      [p] -> mapM (select p) (planWitnesses plan)
      _ -> failAt u name "witness settings require an executable law; instantiate a reusable law in an ordinary law first"
    unless (length (map (inputId . witnessInput) choices) == length (nub (map (inputId . witnessInput) choices)))
      (failAt u name "two witnesses select the same existential binder")
    pure (name, plan { planResolvedWitnesses = choices })
  pure u { lawHarness = plans }
  where
    failAt u law message = Left [Diagnostic "harness" message
      (case [location l | l <- laws u, lawName l == law] of at:_ -> Just at; [] -> Nothing)]
    select p (written, expression, renames, range) = do
      let targets = collect (map inputName (inputs p)) (inputs p) (assertion p)
          path = case written of "definition":rest -> rest; _ -> written
          matching = [target | target@(full,_,_) <- targets,
            path == full || (length path == 1 && last full == head path)]
          problem message = Left [Diagnostic "harness" (message ++ ": " ++ intercalate "." written ++
            "; existential paths are " ++ intercalate ", " ["definition." ++ intercalate "." full | (full,_,_) <- targets])
            (Just (spanStart range))]
      case matching of
        [(full, target, scope)] -> do
          let aliases = [(inputName i, Var (inputId i)) | i <- reverse scope]
              imported = [(n,value) | (n,value) <- renames, n `notElem` map fst aliases]
              value = replaceExprVars aliases (replaceExprVars imported expression)
          pure (HarnessWitness full target scope value range)
        [] -> problem "no existential binder matches witness target"
        _ -> problem "ambiguous witness target; use its qualified lexical path"
    collect path scope claim = case claim of
      AssertQuantified kind input body ->
        let full = path ++ [inputName input]
        in [(full,input,scope) | kind == ForSome] ++ collect full (scope ++ [input]) body
      AssertNot body -> collect path scope body
      AssertImplies _ body -> collect path scope body
      AssertAll bodies -> concat [collect (path ++ ["branch" ++ show k]) scope body | (k,body) <- zip [1::Int ..] bodies]
      AssertEqual _ _ -> []
