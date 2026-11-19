{-# LANGUAGE GADTs #-}

-- | lawspec lsp --stdio and lawspec mcp in the Haskell application port,
-- over the in-memory host with a scripted standard input: the framing, the
-- order of replies and published diagnostics, the protocol's handshake and
-- errors, and the tools. The expected texts are the legacy servers'
-- (npm/lsp.mjs, npm/mcp.mjs and the MCP SDK); tools/host-parity.mjs
-- compares whole sessions with them over real pipes.
-- ref:DEC-haskell-application-port ref:DEC-host-effect-abi
module ServerSpec (spec) where

import qualified Data.ByteString as B
import qualified Data.ByteString.Char8 as BC
import Data.List (isInfixOf, isPrefixOf)
import LawSpec.App.Json
import LawSpec.App.Lsp (fileUrlToPath, pathToFileUrl, utf16Position)
import LawSpec.App.Main
import LawSpec.App.Mcp (toolList)
import LawSpec.App.Command (newSession, runCommand, utf8)
import LawSpec.Host.Effect
import LawSpec.Host.Fake
import Control.Monad.State.Strict (State)
import Test.Hspec
import Data.Version (showVersion)
import Paths_lawspec (version)

-- | The fake host, answering each input request with at most a few bytes,
-- as a pipe may.
trickling :: Int -> Host (State World) -> Host (State World)
trickling size host = Host perform' (trickling size . confined host)
  where
    perform' :: Effect a -> State World (Either HostError a)
    perform' = \case
      ReadInput limit -> perform host (ReadInput (min size limit))
      other -> perform host other

serve :: Host (State World) -> [String] -> B.ByteString -> World -> (Outcome, World)
serve host arguments input world =
  runFake (lawspecMain host pureCompiler (Invocation arguments "/p" Nothing Nothing Nothing Nothing)) world {worldStdin = input}

project :: World
project =
  withFile "/p/lawspec.edn" (BC.pack "{:manifest-version 1 :component {:name \"p\" :version \"0.1.0\"} :language-profile \"1.0-rc.2\" :sources [\"laws\"] :targets [] :verification {:layers []}}\n") $
    withFile "/p/laws/a.lawspec" (BC.pack source) emptyWorld

source :: String
source = "unit a\nf :: Integer -> Integer\nlaw fixed is definition: for all (x :: Integer) => f x = f x end for all end definition end law\nend unit\n"

framed :: String -> B.ByteString
framed body = let bytes = utf8 body in BC.pack ("Content-Length: " ++ show (B.length bytes) ++ "\r\n\r\n") <> bytes

-- | The bodies of the framed messages written.
frames :: B.ByteString -> [String]
frames bytes
  | B.null bytes = []
  | otherwise =
      let (header, rest) = B.breakSubstring "\r\n\r\n" bytes
          size = read (BC.unpack (B.drop (B.length "Content-Length: ") header))
          body = B.take size (B.drop 4 rest)
       in BC.unpack body : frames (B.drop (size + 4) rest)

json :: String -> Json
json = either error id . parseJson

open' :: String
open' = "{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/didOpen\",\"params\":{\"textDocument\":{\"uri\":\"file:///p/laws/a.lawspec\",\"languageId\":\"lawspec\",\"version\":1,\"text\":" ++ show source ++ "}}}"

spec :: Spec
spec = describe "the language and Model Context Protocol servers" $ do
  describe "lawspec lsp --stdio" $ do
    let session =
          map
            framed
            [ "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file:///p\"}}",
              open',
              "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"textDocument/hover\",\"params\":{\"textDocument\":{\"uri\":\"file:///p/laws/a.lawspec\"},\"position\":{\"line\":1,\"character\":0}}}",
              "{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"shutdown\"}",
              "{\"jsonrpc\":\"2.0\",\"id\":4,\"method\":\"textDocument/hover\",\"params\":{}}",
              "{\"jsonrpc\":\"2.0\",\"method\":\"exit\"}",
              "{\"jsonrpc\":\"2.0\",\"id\":5,\"method\":\"shutdown\"}"
            ]
        expected =
          [ "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"capabilities\":{\"textDocumentSync\":1,\"positionEncoding\":\"utf-16\",\"documentFormattingProvider\":true,\"documentSymbolProvider\":true,\"hoverProvider\":true,\"definitionProvider\":true,\"referencesProvider\":true},\"serverInfo\":{\"name\":\"LawSpec\",\"version\":\"" ++ current ++ "\"}}}",
            "{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/publishDiagnostics\",\"params\":{\"uri\":\"file:///p/laws/a.lawspec\",\"version\":1,\"diagnostics\":[]}}",
            "{\"jsonrpc\":\"2.0\",\"id\":2,\"result\":{\"contents\":{\"kind\":\"plaintext\",\"value\":\"f\\nInteger -> Integer\"},\"range\":{\"start\":{\"line\":1,\"character\":0},\"end\":{\"line\":2,\"character\":0}}}}",
            "{\"jsonrpc\":\"2.0\",\"id\":3,\"result\":null}",
            "{\"jsonrpc\":\"2.0\",\"id\":4,\"error\":{\"code\":-32603,\"message\":\"Server is shutting down\"}}"
          ]
    it "answers each message in order, publishes diagnostics before the reply, and stops at exit" $ do
      let (outcome, world) = serve fakeHost ["lsp", "--stdio"] (B.concat session) project
      outcome `shouldBe` Completed 0
      frames (worldStdout world) `shouldBe` expected
      worldStderr world `shouldBe` B.empty
    it "reassembles messages that arrive a few bytes at a time" $ do
      let (outcome, world) = serve (trickling 7 fakeHost) ["lsp", "--stdio"] (B.concat session) project
      outcome `shouldBe` Completed 0
      frames (worldStdout world) `shouldBe` expected
    it "publishes a changed document's errors at their UTF-16 positions" $ do
      let change = "{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/didChange\",\"params\":{\"textDocument\":{\"uri\":\"file:///p/laws/a.lawspec\",\"version\":2},\"contentChanges\":[{\"text\":\"unit a\\n\\t\240\159\152\128 :: Intger -> Integer\\nend unit\\n\"}]}}"
          (_, world) = serve fakeHost ["lsp", "--stdio"] (B.concat (map framed [open', change])) project
      case drop 1 (frames (worldStdout world)) of
        [published] -> do
          (member "version" =<< member "params" (json published)) `shouldBe` Just (integer 2)
          fmap (map (member "range")) (member "params" (json published) >>= member "diagnostics" >>= arrayOf)
            `shouldSatisfy` maybe False (\ranges -> not (null ranges) && all (/= Nothing) ranges)
        other -> expectationFailure (show other)
    it "answers an unknown request, a malformed message and a notification's failure" $ do
      let (_, world) =
            serve
              fakeHost
              ["lsp", "--stdio"]
              ( B.concat
                  [ framed "{\"jsonrpc\":\"2.0\",\"id\":\"a\",\"method\":\"workspace/symbol\"}",
                    framed "{oops",
                    framed "{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/didChange\",\"params\":{\"textDocument\":{\"uri\":\"file:///p/laws/a.lawspec\"},\"contentChanges\":[{\"range\":{},\"text\":\"\"}]}}",
                    framed "{\"jsonrpc\":\"2.0\",\"id\":7,\"method\":\"textDocument/didOpen\",\"params\":{}}"
                  ]
              )
              project
      frames (worldStdout world)
        `shouldBe` [ "{\"jsonrpc\":\"2.0\",\"id\":\"a\",\"error\":{\"code\":-32601,\"message\":\"Method not found\"}}",
                     "{\"jsonrpc\":\"2.0\",\"id\":null,\"error\":{\"code\":-32700,\"message\":\"Parse error\"}}",
                     "{\"jsonrpc\":\"2.0\",\"method\":\"window/logMessage\",\"params\":{\"type\":1,\"message\":\"LawSpec requires full-document synchronization\"}}",
                     "{\"jsonrpc\":\"2.0\",\"id\":7,\"error\":{\"code\":-32603,\"message\":\"Cannot read properties of undefined (reading 'uri')\"}}"
                   ]
    it "stops at a header without a Content-Length" $ do
      let (outcome, world) = serve fakeHost ["lsp", "--stdio"] (BC.pack "Content-Type: x\r\n\r\n" <> framed "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"shutdown\"}") project
      outcome `shouldBe` Completed 0
      frames (worldStdout world) `shouldBe` ["{\"jsonrpc\":\"2.0\",\"id\":null,\"error\":{\"code\":-32700,\"message\":\"Invalid Content-Length\"}}"]
    it "reads a Content-Length header in any case, among other headers" $ do
      let (_, world) = serve fakeHost ["lsp", "--stdio"] (BC.pack "Content-Type: x\r\ncontent-length: 39 \r\n\r\n{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"x\"}  ") project
      frames (worldStdout world) `shouldBe` ["{\"jsonrpc\":\"2.0\",\"id\":1,\"error\":{\"code\":-32601,\"message\":\"Method not found\"}}"]
    it "converts positions and file URLs as lsp.mjs and Node do" $ do
      utf16Position "a\tb\128512c" (json "{\"line\":1,\"column\":10}") `shouldBe` (0, 3)
      utf16Position "a\tb\128512c" (json "{\"line\":1,\"column\":11}") `shouldBe` (0, 5)
      -- From npm/test/authoring.test.mjs and match-warnings.test.mjs (0.36.0).
      utf16Position "a\128512b\n\t\128512x\n" (json "{\"line\":1,\"column\":3}") `shouldBe` (0, 3)
      utf16Position "a\128512b\n\t\128512x\n" (json "{\"line\":2,\"column\":10}") `shouldBe` (1, 3)
      utf16Position "\128512\twhen" (json "{\"line\":1,\"column\":9}") `shouldBe` (0, 3)
      pathToFileUrl "/a b/c%d#e?f~g\233" `shouldBe` "file:///a%20b/c%25d%23e%3Ff%7Eg%C3%A9"
      fst (fst (runFake (runCommand (newSession fakeHost pureCompiler) (fileUrlToPath (JString "file:///a%20b/../c"))) emptyWorld))
        `shouldBe` Right "/c"
  describe "lawspec mcp" $ do
    let line value = BC.pack (value ++ "\n")
        initialize identifier = line ("{\"jsonrpc\":\"2.0\",\"id\":" ++ identifier ++ ",\"method\":\"initialize\",\"params\":{\"protocolVersion\":\"1999-01-01\",\"capabilities\":{},\"clientInfo\":{\"name\":\"t\",\"version\":\"1\"}}}")
        call identifier name arguments = line ("{\"jsonrpc\":\"2.0\",\"id\":" ++ identifier ++ ",\"method\":\"tools/call\",\"params\":{\"name\":\"" ++ name ++ "\",\"arguments\":" ++ arguments ++ "}}")
        replies world = lines (BC.unpack (worldStdout world))
    it "negotiates the protocol, lists its tools and answers until standard input ends" $ do
      let (outcome, world) =
            serve
              (trickling 5 fakeHost)
              ["mcp"]
              ( B.concat
                  [ initialize "1",
                    line "{\"jsonrpc\":\"2.0\",\"method\":\"notifications/initialized\"}",
                    line "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/list\"}",
                    line "not json",
                    line "{\"jsonrpc\":\"2.0\",\"id\":2.5,\"method\":\"ping\"}",
                    BC.pack "{\"jsonrpc\":\"2.0\",\"id\":\"p\",\"method\":\"ping\"}\r\n",
                    line "{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"prompts/list\"}",
                    BC.pack "{\"jsonrpc\":\"2.0\",\"id\":4,\"method\":\"ping\"}"
                  ]
              )
              project
      outcome `shouldBe` Completed 0
      replies world
        `shouldBe` [ "{\"result\":{\"protocolVersion\":\"2025-11-25\",\"capabilities\":{\"tools\":{\"listChanged\":true}},\"serverInfo\":{\"name\":\"lawspec\",\"version\":\"" ++ current ++ "\"}},\"jsonrpc\":\"2.0\",\"id\":1}",
                     "{\"result\":" ++ compact toolList ++ ",\"jsonrpc\":\"2.0\",\"id\":2}",
                     "{\"result\":{},\"jsonrpc\":\"2.0\",\"id\":\"p\"}",
                     "{\"jsonrpc\":\"2.0\",\"id\":3,\"error\":{\"code\":-32601,\"message\":\"Method not found\"}}"
                   ]
    it "reports invalid requests and arguments as the SDK does" $ do
      let (_, world) =
            serve
              fakeHost
              ["mcp"]
              ( B.concat
                  [ line "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"protocolVersion\":\"2025-06-18\"}}",
                    line "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/call\",\"params\":{\"arguments\":[]}}",
                    call "3" "lawspec_nothing" "{}",
                    call "4" "lawspec_explain" "{\"view\":\"x\"}"
                  ]
              )
              project
      map json (replies world)
        `shouldBe` map
          json
          [ "{\"jsonrpc\":\"2.0\",\"id\":1,\"error\":{\"code\":-32603,\"message\":\"[\\n  {\\n    \\\"expected\\\": \\\"object\\\",\\n    \\\"code\\\": \\\"invalid_type\\\",\\n    \\\"path\\\": [\\n      \\\"params\\\",\\n      \\\"capabilities\\\"\\n    ],\\n    \\\"message\\\": \\\"Invalid input: expected object, received undefined\\\"\\n  },\\n  {\\n    \\\"expected\\\": \\\"object\\\",\\n    \\\"code\\\": \\\"invalid_type\\\",\\n    \\\"path\\\": [\\n      \\\"params\\\",\\n      \\\"clientInfo\\\"\\n    ],\\n    \\\"message\\\": \\\"Invalid input: expected object, received undefined\\\"\\n  }\\n]\"}}",
            "{\"jsonrpc\":\"2.0\",\"id\":2,\"error\":{\"code\":-32602,\"message\":\"Invalid tools/call request: [\\n  {\\n    \\\"expected\\\": \\\"string\\\",\\n    \\\"code\\\": \\\"invalid_type\\\",\\n    \\\"path\\\": [\\n      \\\"params\\\",\\n      \\\"name\\\"\\n    ],\\n    \\\"message\\\": \\\"Invalid input: expected string, received undefined\\\"\\n  },\\n  {\\n    \\\"expected\\\": \\\"record\\\",\\n    \\\"code\\\": \\\"invalid_type\\\",\\n    \\\"path\\\": [\\n      \\\"params\\\",\\n      \\\"arguments\\\"\\n    ],\\n    \\\"message\\\": \\\"Invalid input: expected record, received array\\\"\\n  }\\n]\"}}",
            "{\"jsonrpc\":\"2.0\",\"id\":3,\"error\":{\"code\":-32602,\"message\":\"Tool lawspec_nothing not found\"}}",
            "{\"result\":{\"content\":[{\"type\":\"text\",\"text\":\"Input validation error: Invalid arguments for tool lawspec_explain: law: Invalid input: expected string, received undefined, view: Invalid option: expected one of \\\"eng\\\"|\\\"math\\\"|\\\"dev\\\"\"}],\"isError\":true},\"jsonrpc\":\"2.0\",\"id\":4}"
          ]
    it "runs the project tools over the compiler in-process" $ do
      let (_, world) = serve fakeHost ["mcp"] (B.concat [initialize "1", call "2" "lawspec_list_laws" "{}", call "3" "lawspec_explain" "{\"law\":\"a::fixed\"}", call "4" "lawspec_inspect" "{\"target\":\"go\"}"]) project
      case map json (drop 1 (replies world)) of
        [listed, explained, inspected] -> do
          let text value = member "result" value >>= member "content" >>= arrayOf >>= \case
                item : _ -> member "text" item >>= stringOf
                [] -> Nothing
          fmap (\t -> "\"id\": \"a::fixed\"" `isInfixOf` t) (text listed) `shouldBe` Just True
          fmap (not . null) (text explained) `shouldBe` Just True
          (member "isError" =<< member "result" explained) `shouldBe` Nothing
          text inspected `shouldBe` Just "No matching configured target"
        other -> expectationFailure (show other)
    it "reports a project tool's failure where there is no lawspec.edn" $ do
      let (_, world) = serve fakeHost ["mcp"] (call "1" "lawspec_check" "{}") (withDirectory "/p" emptyWorld)
      fmap ("/p: No lawspec.edn found" `isPrefixOf`) ((case replies world of reply : _ -> member "result" (json reply); [] -> Nothing) >>= member "content" >>= arrayOf >>= \case
        item : _ -> member "text" item >>= stringOf
        [] -> Nothing)
        `shouldBe` Just True

-- | The version the servers report: the package version.
current :: String
current = showVersion version
