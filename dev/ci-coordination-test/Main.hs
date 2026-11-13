-- | Exercise what lawspec-dev ci decides and shares outside its steps: which
-- steps a selection or a change runs (Ci.Select), and the job slots and
-- locks concurrent runs hold (Ci.Budget), including a holder that is killed.
--
--   runghc -idev dev/ci-coordination-test/Main.hs
--
-- With `hold <file>` it is the other process of its own test: it holds the
-- file's lock and waits to be killed.
module Main where

import Ci.Budget
import Ci.Cache (recordAtomically)
import Ci.Select
import Control.Concurrent (forkIO, threadDelay)
import Control.Concurrent.MVar (newEmptyMVar, putMVar, takeMVar, tryTakeMVar)
import Control.Exception (IOException, bracket, try)
import Control.Monad (forM_, unless, when)
import Data.Maybe (isJust, isNothing)
import qualified Data.Set as S
import System.Directory
import System.Environment (getArgs)
import System.FilePath ((</>))
import System.IO (BufferMode(..), hClose, hGetLine, hSetBuffering, openTempFile, stdout)
import System.Process (CreateProcess(..), StdStream(..), createProcess, proc, terminateProcess, waitForProcess)

main :: IO ()
main = getArgs >>= \arguments -> case arguments of
  ["hold", file] -> do
    hSetBuffering stdout LineBuffering
    held <- tryHold file
    putStrLn (if isJust held then "held" else "busy")
    threadDelay 60000000
  _ -> do
    selection
    bracket temporary removePathForcibly $ \root -> do
      records root
      slots root
      killedHolder root
    putStrLn "CI selection, atomic records, job slots, machine locks and killed-holder controls passed."

expect :: (Eq a, Show a) => String -> a -> a -> IO ()
expect message actual expected =
  unless (actual == expected) (fail (message ++ ": " ++ show actual ++ ", expected " ++ show expected))

selection :: IO ()
selection = do
  forM_
    [ ("rust-*", "rust-domain", True), ("rust-*", "go-domain", False), ("*-domain", "rust-domain", True)
    , ("*-domain", "rust-domain-32-compact", False), ("*domain*", "rust-domain-32-compact", True)
    , ("docs", "docs", True), ("docs", "docs-check", False), ("doc?", "docs", True), ("doc?", "doc", False)
    , ("*", "", True), ("", "", True), ("", "docs", False), ("a*b*c", "a-b-b-c", True), ("a*b*c", "a-b-b", False)
    , ("a.c", "abc", False), ("[ab]", "a", False) ]
    $ \(pattern', name, result) -> expect ("matches " ++ show pattern' ++ " " ++ show name) (matches pattern' name) result
  let follows =
        [ ("build", ["tests"]), ("tests", []), ("bootstrap", []), ("warm", ["bootstrap", "build"])
        , ("suite", ["bootstrap", "build", "warm", "absent"]), ("docs", []) ]
  expect "prerequisites are transitive and skip absent steps"
    (withPrerequisites follows (S.fromList ["suite"])) (S.fromList ["suite", "bootstrap", "build", "warm", "tests"])
  expect "a step without prerequisites runs alone" (withPrerequisites follows (S.fromList ["docs"])) (S.fromList ["docs"])
  expect "an unknown selection selects nothing" (withPrerequisites follows (S.fromList ["absent"])) S.empty
  let kept = reading ["npm/", "tools/smoke.mjs"] ["npm/test/"]
      everything = reading [] ["docs/"]
      retained = also (== "docs/index.md") everything
  expect "kept root" (readsFile kept "npm/api.mjs") True
  expect "dropped root inside a kept one" (readsFile kept "npm/test/a.test.mjs") False
  expect "outside the kept roots" (readsFile kept "src/LawSpec/Api.hs") False
  expect "a kept file" (readsFile kept "tools/smoke.mjs") True
  expect "an empty keep list keeps every file" (readsFile everything "src/LawSpec/Api.hs") True
  expect "a dropped root" (readsFile everything "docs/how-to/x.md") False
  expect "a retained file under a dropped root" (readsFile retained "docs/index.md") True
  let steps = [("package", Just kept), ("pages", Just (reading ["docs/"] [])), ("undeclared", Nothing)]
  expect "a change selects the steps that read it and those that declare nothing"
    (affected ["npm/api.mjs"] steps) (S.fromList ["package", "undeclared"])
  expect "any of several changes selects" (affected ["README.md", "docs/a.md"] steps) (S.fromList ["pages", "undeclared"])
  expect "a change nobody declares still selects the undeclared" (affected ["LICENSE"] steps) (S.fromList ["undeclared"])
  expect "no change selects nothing" (affected [] steps) S.empty

-- | A record is whole when it appears, and a failed write leaves neither a
-- record nor its temporary file.
records :: FilePath -> IO ()
records root = do
  let recorded = root </> "store" </> "key"
  recordAtomically recorded (`writeFile` "first")
  readFile recorded >>= \content -> expect "record" content "first"
  recordAtomically recorded (`writeFile` "second")
  readFile recorded >>= \content -> expect "replacement" content "second"
  outcome <- try (recordAtomically (root </> "store" </> "other") (\_ -> ioError (userError "disk full"))) :: IO (Either IOException ())
  expect "a failed write is reported" (either (const True) (const False) outcome) True
  listDirectory (root </> "store") >>= \entries -> expect "nothing but the record remains" entries ["key"]

slots :: FilePath -> IO ()
slots root = do
  budget <- newBudget root 2
  expect "budget size" (budgetSize budget) 2
  small <- newBudget root 0
  expect "a budget has at least one slot" (budgetSize small) 1
  -- Two steps hold both slots; a third starts only when one is released.
  first <- newEmptyMVar
  second <- newEmptyMVar
  third <- newEmptyMVar
  release1 <- newEmptyMVar
  release2 <- newEmptyMVar
  _ <- forkIO (withSlot budget (putMVar first () >> takeMVar release1))
  _ <- forkIO (withSlot budget (putMVar second () >> takeMVar release2))
  takeMVar first >> takeMVar second
  _ <- forkIO (withSlot budget (putMVar third ()))
  threadDelay 600000
  tryTakeMVar third >>= \started -> expect "a third step waits for a slot" started Nothing
  putMVar release1 ()
  takeMVar third
  -- A step that takes every slot waits for the one still held.
  alone <- newEmptyMVar
  _ <- forkIO (withEverySlot budget (putMVar alone ()))
  threadDelay 600000
  tryTakeMVar alone >>= \started -> expect "a step that runs alone waits for every slot" started Nothing
  putMVar release2 ()
  takeMVar alone
  -- A named lock admits one holder; another name is independent.
  inside <- newEmptyMVar
  leave <- newEmptyMVar
  other <- newEmptyMVar
  _ <- forkIO (withMachineLock root "warm" (putMVar inside () >> takeMVar leave))
  takeMVar inside
  _ <- forkIO (withMachineLock root "warm" (putMVar other ()))
  withMachineLock root "unrelated" (pure ())
  threadDelay 600000
  tryTakeMVar other >>= \started -> expect "a held lock excludes" started Nothing
  putMVar leave ()
  takeMVar other

-- | Another process holds a slot and is killed: the slot is free again
-- without anyone cleaning up.
killedHolder :: FilePath -> IO ()
killedHolder root = do
  let file = root </> "jobs" </> "slot-0"
  (_, Just output, _, holder) <- createProcess
    (proc "runghc" ["-idev", "dev/ci-coordination-test/Main.hs", "hold", file]) { std_out = CreatePipe, std_err = NoStream }
  line <- hGetLine output
  expect "the other process holds the slot" line "held"
  busy <- tryHold file
  when (isJust busy) (fail "a slot held by another process was taken")
  terminateProcess holder
  _ <- waitForProcess holder
  hClose output
  free <- tryHold file
  when (isNothing free) (fail "a killed holder kept its slot")
  mapM_ hClose free

temporary :: IO FilePath
temporary = do
  parent <- getTemporaryDirectory
  (file, handle) <- openTempFile parent "lawspec-ci-coordination-"
  hClose handle
  removeFile file
  createDirectory file
  pure file
