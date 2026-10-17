-- Runtime validation of nested projections, independent of property search.
import Control.Monad (forM_, unless)
import Data.Either (isLeft)
import qualified LawSpecRuntime as R
import qualified LawSpecSchema as S

main :: IO ()
main = do
 let chain=S.Named "Chain" []; inner=S.Named "lawspec::structural::record::inner" []
     outer=S.Named "lawspec::structural::record::outer" []; wrapper=S.Named "Wrapper" []
     schema=either error id (S.createIndexed
       [S.Definition "Chain" 0 [S.Constructor "Stop" [],S.Constructor "Next" [S.Field "tail" chain]],
        S.Definition "lawspec::structural::record::inner" 0 [S.Constructor "Inner" [S.Field "rest" chain]],
        S.Definition "lawspec::structural::record::outer" 0 [S.Constructor "Outer" [S.Field "child" inner,S.Field "sibling" chain]],
        S.Definition "Wrapper" 0 [S.Constructor "Wrap" [S.Field "payload" outer]]]
       [] [] [("Stop",["c0","c10"]),("Next",["+ f0 c1","+ f0.1 c1"]),
        ("Wrap",["p0/0/0.0","p0/0/0.1","== p0/0/0.1 + p0/1.0 c10","== p0/0/0.0 p0/1.0",">= p0/0/0.0 c1"])])
     stop=R.SData "Stop" []; one=R.SData "Next" [stop]; two=R.SData "Next" [one]
     wrap left right=R.SData "Wrap" [R.SData "Outer" [R.SData "Inner" [left],right]]
 forM_ [32,64] $ \bits -> do
   unless (S.validate schema wrapper bits (wrap two two)==Right (wrap two two)) (error "rejected valid nested path")
   forM_ [wrap two one,wrap stop stop] $ \bad ->
     unless (isLeft (S.validate schema wrapper bits bad)) (error "accepted mismatched or underflowing indices")
 putStrLn "index path conformance: Haskell, both widths"
