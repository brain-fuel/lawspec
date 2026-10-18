-- | The actual native test slots for the shared model-check identities.
-- Some frameworks run a whole machine in one method; a passed completion of
-- that method covers each included check, while a failure covers none.
module LawSpec.NativeModelChecks (NativeCheck(..), nativeChecks, collisions) where

import Data.Char (toUpper)
import Data.List (intercalate,nub)
import qualified Data.Map.Strict as M
import qualified LawSpec.Core as C
import LawSpec.Core.Machine
import qualified LawSpec.Core.Program as P
import qualified LawSpec.BeamModelChecks as Checks
import qualified LawSpec.Groovy.Emit as Groovy
import LawSpec.Groovy.Spock (specClassName)
import qualified LawSpec.Clojure.Emit as Clojure
import LawSpec.Testing (PlannedUnit(..))

data NativeCheck = NativeCheck
  { checkEvidence :: Checks.Check, checkFile :: FilePath, checkTestName :: String
  , checkScope :: Maybe String, checkGroup :: String }

nativeChecks :: String -> FilePath -> C.Unit -> [NativeCheck]
nativeChecks target lawFile unit
  | target `notElem` supported=[]
  | otherwise=map native (Checks.checks unit)
  where
    supported=["python","javascript","typescript","go","java","kotlin","scala","groovy","clojure","haskell","rust"]
    owner=C.idText (C.unitId unit)
    parts=split '.' owner
    cls=concatMap capital (split '_' (last parts))++"ModelTest"
    javaScope=intercalate "." (init parts++[cls])
    title language=if language=="groovy" then Groovy.groovyTestTitle (PlannedUnit unit [])
      else Clojure.clojureTestTitle (PlannedUnit unit [])
    clojureScope=intercalate "." (map (title "clojure") (init parts)++[title "clojure" cls])
    haskellModule=intercalate "." (map (concatMap capital . split '_') (init parts)++
      [concatMap capital (split '_' (last parts))++"Model"])
    file=case target of
      "go"->intercalate "/" parts++"/lawspec_models_test.go"
      "java"->jvm "java" cls ".java"
      "kotlin"->jvm "kotlin" cls ".kt"
      "scala"->jvm "scala" cls ".scala"
      "groovy"->jvm "groovy" (specClassName cls) ".groovy"
      "clojure"->"test/"++map (\c->case c of '.'->'/'; '-'->'_'; _->c) clojureScope++".clj"
      "haskell"->"test/"++map (\c->if c=='.' then '/' else c) haskellModule++"Spec.hs"
      _->lawFile
    scope=case target of
      "java"->Just javaScope
      "kotlin"->Just javaScope
      "scala"->Just javaScope
      "groovy"->Just (intercalate "." (init parts++[specClassName cls]))
      "clojure"->Just clojureScope
      "haskell"->Just haskellModule
      _->Nothing
    jvm language name extension="src/test/"++language++"/"++intercalate "/" (init parts++[name])++extension
    native check=case Checks.checkAction check of
      Checks.Supervision->make check Nothing "supervision"
      Checks.Sequential _ machine->make check (Just (machineName machine)) "sequential"
      Checks.Parallel _ machine->make check (Just (machineName machine)) "parallel"
      Checks.Scenario _ machine program->make check (Just (machineName machine)) ("scenario:"++P.programTitle program)
    make check machine role=NativeCheck check file name scope group
      where
        grouped=target `notElem` ["python","javascript","typescript"]
        group=maybe "supervision" (\m->"model:"++m++if grouped then "" else ":"++role) machine
        javaName=maybe "supervision" (("model"++).capital) machine
        name=case target of
          "python"->case (machine,Checks.checkAction check) of
            (Nothing,_)->"test_supervision"
            (Just m,Checks.Sequential{})->"test_model_"++m
            (Just m,Checks.Parallel{})->"test_model_"++m++"_parallel"
            (Just m,Checks.Scenario _ model program)->"test_model_"++m++"_scenario"++show
              (length (takeWhile ((/=P.programTitle program).P.programTitle) (machineScenarios model)))
            _->error "unknown model check"
          "javascript"->Checks.checkLabel check
          "typescript"->Checks.checkLabel check
          "go"->maybe "TestSupervision" (("TestModel"++).capital) machine
          "java"->javaName
          "groovy"->title "groovy" javaName
          "clojure"->title "clojure" javaName
          "kotlin"->maybe (owner++"::supervision") (\m->owner++"::model "++m) machine
          "scala"->maybe (owner++"::supervision") (\m->owner++"::model "++m) machine
          "haskell"->maybe "supervision" ("model "++) machine
          "rust"->maybe "supervision" ("model_"++) machine
          _->error "unsupported native model check target"

-- Distinct logical groups cannot share a native slot. Aliases for a single
-- combined method intentionally do. Reject ambiguous generated names rather
-- than attributing one group's completion to another group.
collisions :: [NativeCheck] -> [String]
collisions entries=[file++":"++name | ((file,name),groups)<-M.toList slots,length (nub groups)>1]
  where slots=M.fromListWith (++) [((checkFile entry,checkTestName entry),[checkGroup entry]) | entry<-entries]

capital :: String -> String
capital (c:rest)=toUpper c:rest
capital []=[]
split :: Char -> String -> [String]
split separator text=case break (==separator) text of
  (part,[])->[part]
  (part,_:rest)->part:split separator rest
