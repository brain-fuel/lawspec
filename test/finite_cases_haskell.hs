-- \| Independent finite-cover observations against the maintained runtime.
-- ref:DEC-planned-generation
import Control.Exception (ErrorCall, evaluate, try)
import Control.Monad (unless)
import qualified LawSpecRuntime as LS

check :: String -> Bool -> IO ()
check name holds = unless holds (error name)

main :: IO ()
main = do
  let range = LS.FiniteRange (0 :: Integer) 2 id
      cover = LS.FiniteBranches [(range, LS.FiniteBranches [(LS.FiniteValues [10, 20], LS.FiniteCopies 1)])]
  check "Cartesian order" $
    LS.finiteCases cover == zip [0 ..] [[a, b] | a <- [0 .. 2], b <- [10, 20]]
  let dependent =
        LS.FiniteBranches
          [ (LS.FiniteValues [0], LS.FiniteBranches [(LS.FiniteValues [5, 5], LS.FiniteCopies 1)]),
            (LS.FiniteValues [1], LS.FiniteBranches [(LS.FiniteValues [9], LS.FiniteCopies 2)])
          ]
  check "dependent rows and duplicates" $
    LS.finiteCases dependent == zip [0 ..] [[0, 5], [0, 5], [1, 9], [1, 9]]
  check "no cases" $ null (LS.finiteCases (LS.FiniteBranches [] :: LS.FiniteCover Integer))
  check "one case without inputs" $ LS.finiteCases (LS.FiniteCopies 1 :: LS.FiniteCover Integer) == [(0, [])]
  let maximumValue = 2 ^ (64 :: Int) - 1
  check "inclusive UInt64 maximum" $
    LS.finiteCases (LS.FiniteBranches [(LS.FiniteRange (maximumValue - 1) maximumValue id, LS.FiniteCopies 1)])
      == [(0, [maximumValue - 1]), (1, [maximumValue])]
  check "huge lazy cover" $
    take 3 (LS.finiteCases (LS.FiniteBranches [(LS.FiniteRange 0 (2 ^ (128 :: Int)) id, LS.FiniteCopies 1)]))
      == [(0, [0]), (1, [1]), (2, [2])]
  check "an unvisited suffix is not evaluated" $
    take 1 (LS.finiteCases (LS.FiniteBranches [(LS.FiniteValues [42], LS.FiniteCopies 1), (error "visited later branch", LS.FiniteCopies 1)])) == [(0, [42 :: Integer])]
  first <- LS.newSymbolContext
  second <- LS.newSymbolContext
  let factories = LS.FiniteBranches [(LS.FiniteValues [\symbols -> LS.scopeSymbols symbols (LS.SSymbol "same" "same")], LS.FiniteCopies 1)]
      factory = head (snd (head (LS.finiteCases factories)))
  check "each attempt gets its own symbol context" $
    LS.equal (factory first) (factory first) && not (LS.equal (factory first) (factory second))
  rejected <- try (evaluate (length (LS.finiteCases (LS.FiniteCopies (-1) :: LS.FiniteCover Integer)))) :: IO (Either ErrorCall Int)
  check "negative case multiplicity is rejected" $ either (const True) (const False) rejected
  putStrLn "Haskell finite-cover conformance passed"
