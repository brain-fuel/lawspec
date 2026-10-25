-- Embedded runtime text must remain the same text, including supplementary
-- characters and digits adjacent to an escape. ref:DEC-generated-javascript
import Control.Monad (unless)
import Gen.Embed (quote)

main :: IO ()
main = do
  let samples = [map toEnum [0..255], " — ", "\x1f600" ++ "0123abcdef",
                 "\x10ffff" ++ "F", "\NUL" ++ "9", "\"\\\n\r\t"]
  mapM_ (\source -> unless ((read (quote source) :: String) == source)
    (fail "embedded Haskell literal changed runtime text")) samples
  putStrLn "Embedded Haskell string literals preserve Unicode and adjacent digits"
